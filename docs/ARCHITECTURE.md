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
    **Folders:** FXServer cannot create a folder on Linux: `os.createdir` makes it and then crashes the whole server
    (signal 11, pcall cannot catch it), `SaveResourceFile` and `io.open` make none and `os.execute` is refused. So
    every folder Crimson-Police writes ships with it (a `.gitkeep` each, kept by `.gitignore`), a file is never put
    in a folder made at run time, and a folder is checked with `CP.U.ensureFolder(dir, canWrite) -> true | false,
    'missing'|'readonly'` (only a Windows server makes a missing one) and reported with `CP.U.folderAdvice(dir,
    why)`. tests/harness.lua ends a spec at once (exit 139) when resource code calls `os.createdir`.

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
      when Crimson-Arena wipes it; downed pick-ups re-check; mission items carry `{ cpRun, cpItem }` metadata
      (removed only from a slot whose own metadata has those keys: ox_inventory's Search matches values only);
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
    shared/npccombat.lua           CP.NpcCombat: the weapon a mission NPC may carry, the accuracy and firing caps (§5.42)
    shared/twists.lua              CP.Twists: a run's twists (the modifiers officers choose) and their stacked bonus (§5.9)
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
    missions/custom/overrides/     edited built-in missions (<id>.lua, <id>.base.lua; archived/), §5.28
    missions/custom/deleted/       missions deleted for good from the Admin UI (Bring back moves them back)
    modules/<feature>/server.lua   (+ client.lua where needed)
    modules/integrations/<name>/server.lua (+ client.lua)
    modules/storage/memsql.lua     CP.Storage.MemSQL: SQL engine + saves folder for database-off mode (server)
    modules/storage/server.lua     CP.Storage: picks MySQL/MariaDB or the saves folder (Config.Database)
    saves/                         database-off data (JSON documents, _tables.json); only README.md is committed;
                                   saves/_backups/ (System → Backups, both storage modes), saves/exports/ (audit CSV),
                                   both shipped empty with a .gitkeep
    blocks/<block_id>/server.lua + client.lua
    web/                           React 18 + TS + Vite; builds to web/dist (committed); README.md points to
                                   docs/WEB_UI.md
    sql/migrations/001_initial.sql, 002_test_def_hash.sql, 003_run_stats.sql, 004_profile.sql,
                   005_mission_calls.sql, 006_item_rewards.sql, 007_settings.sql, 008_admin_control.sql,
                   009_real_suspects.sql
```

fxmanifest loads: `@ox_lib/init.lua`, config/config.lua, config/blocks.lua, shared/*.lua
(alphabetical: init, locale, net, npccombat, utils), then `modules/**/server.lua` (server) /
`modules/**/client.lua` (client), then `blocks/**/server.lua` / `blocks/**/client.lua`.
Server also gets `@oxmysql/lib/MySQL.lua`, then `modules/storage/memsql.lua` and
`modules/storage/server.lua` before every other server module (so the `MySQL` global is settled before
any module can query), then `modules/adminkit/server.lua` (so any module may register its admin actions with
`CP.AdminKit.action` as it loads). `files` ships web/dist, locales/*.json and logos/*.

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

`modules/npccombat/` (client, server, §5.42): the run-scoped damage settings of an officer's game (Config.NpcCombat), the
protection drop and the `crimsonPoliceRun` player bag.

`modules/markers/` (client, §5.44): the current objective's pointer on the officer's map and its one GPS line
(Config.Markers).

`modules/spawn/` (client, server, §5.43): what an officer's game can see of the spawn director's points
(Config.Spawning.preferHidden), the ground probe of one point (Config.Spawning.ground), the placer that puts a
new mission entity on the ground when the server asks (Config.Spawning.place), and the server's side of it: the ask
written for every new mission entity, the answers, another point after a bad one, the time limit.

`modules/settings/` (server, client, §5.36): settings changed in game (Admin UI → Settings) over config.lua and
blocks.lua, the mission and location switches, and the same values on every client.

`modules/adminkit/` (server, §5.37): full admin control's foundation. `CP.AdminKit` (the guard wrapper of every new
admin action, previews, request ids, jobs, day counts, the busy lock) and `CP.Maintenance` (the maintenance lock).
The packages of that build add `modules/corrections/` (§5.38), `modules/livectl/` (§5.39), `modules/payments/`
(§5.40) and `modules/sysadmin/` (§5.41).

---

## 2. Shared layer (already written — read the files)

| API | File | Notes |
|---|---|---|
| `CP.resource`, `CP.isServer`, `CP.prefix` | shared/init.lua | `GetCurrentResourceName()` (`'Crimson-Police'`; everything inside the resource follows a renamed folder, see §5.34 `folder`), bool, `'crimson-police'` |
| `CP.log(tag, fmt, ...)`, `CP.warn`, `CP.err` | shared/init.lua | tagged `[crimson-police:<tag>]`. On the server every `warn`/`err` line is also kept (below) |
| `CP.Problems.list({ tag?, level?, limit? }) -> { { at, level = 'warn'\|'error', tag, text } }`, `CP.Problems.total()`, `CP._logSink` | shared/init.lua | Server: a ring buffer of the last 200 `CP.warn`/`CP.err` lines from the first line of `shared/init.lua` on (start-up lines included), newest first. Before a line is kept, webhook links (`https://<host>/api/webhooks/...`), `mysql://...` connection strings, `password=`/`pwd=` values and full licences (`license:` keeps its last 4 characters) are cut out (`CP._redact(text)`). `CP._logSink`, when a module sets it to a function, gets every kept entry (the System → Problems screen) |
| `CP.e(name)` | shared/init.lua | `'crimson-police:' .. name` |
| `CP.configProblem(cfg) -> nil \| 'error'\|'warn', text` | shared/init.lua | The config load check: `'error'` when `Config` is not a table (config.lua did not load), `'warn'` naming the table sections of config.lua and blocks.lua that are missing (config.lua stopped at an error, or is from an older version). The server prints it once as the file loads (tag `config`), before any module can fail on it |
| `CP.Blocks.register(id, impl)`, `.get(id)`, `.all()` | shared/init.lua | one registry per side |
| `CP.L(key, vars)`, `CP.Locale.all()`, `CP.Locale.has(key)`, `CP.Locale.inFile(key)` | shared/locale.lua | `{var}` placeholders. `Config.Labels` (Settings → Names: English names of offences, commendation kinds, badges, bonuses, penalties) is read first by `CP.L`, `has` and `label`, and merged over the file by `all()`; `inFile` = the key is in `locales/en.json` itself |
| `CP.Lt(key, vars) -> token`, `CP.Locale.isToken(v)`, `encode`, `tokenize(payload)`, `resolve(text, code)`, `resolveAll(payload, code)` | shared/locale.lua | A `{ key, vars }` token for text meant for a player's screen: `CP.Runs.hud`, `ctx.hud` and `ctx.send` accept it and the client resolves it right before `SendNUIMessage` (`CP.Locale.resolveAll`). CP.L is never replaced. English only: every token resolves in the server language |
| `CP.Locale.label(key, fallback, vars)` | shared/locale.lua | The locale text when the key exists, else the fallback (config or mission text): the optional label overrides of §10 |
| `CP.Hooks.on(name, fn) -> id`, `CP.Hooks.off(id) -> bool`, `CP.Hooks.fire(name, ...) -> n` | shared/init.lua | Both sides. Listeners run in the caller's thread, in the order added, each in pcall (a failure is logged, the next still runs). The hooks and who fires them: §5.10 |
| `CP.Net.action(name, handler, opts)` | shared/net.lua | server: registers net event `crimson-police:<name>`; handler `(src, payload) -> ok, data|errKey`; replies to `reqId`. While `CP.Maintenance.active()` (§5.37) every action is refused with `err.maintenance` before its handler runs, unless it was registered with `opts.maintenance = true` (status reads and the actions that end a lock). Callbacks are never gated by the lock. After a failed start (`CP.Migrations.failed()`) every action is refused with `err.not_started` before its handler runs, and a handler that raised it while it waited for the start answers it too |
| `CP.Net.callback(name, handler, opts)` | shared/net.lua | server: ox_lib callback `crimson-police:<name>`; handler `(src, args) -> data` or `nil, errKey`; reply `{ok,data,error}`. After a failed start every callback answers `err.not_started` before its handler runs. `opts.latent = true` (the three big exports `admin:exportAudit`, `admin:exportAuditPart`, `admin:exportPayments`; `Kit.callback` passes it through): when the client sent a reply id (the callback's second argument after `args`), the data goes as `TriggerLatentClientEvent('crimson-police:client:actionResult', src, Config.Limits.exportBps, id, true, data)` and the callback answers `{ ok = true, latent = id }`, so up to 5000 CSV rows no longer hold back the admin's other events (`exportBps` 200000; below 100000 counts as 100000; 0 = one plain answer, as before) |
| `CP.Net.rateOk(src, key, max, windowMs)` | shared/net.lua | server: a token bucket per (src, key): `max` calls at once, then one back every `windowMs / max` (a new key starts full; `playerDropped` clears the player's buckets). `CP.Net.action` (`opts.rate`, default 8 a second) and `CP.Net.callback` (default 6) answer `err.rate_limited` past it. `Config.Limits.netRateResponse` (read at each refusal): `'block'` (shipped) refuses quietly; `'log'` also prints one `CP.warn('net', ...)` a minute per player once one name is refused 3 x its limit in a minute; `'kick'` prints that warning and calls `DropPlayer(src, CP.L('err.rate_kick'))` once |
| `CP.Net.action(name, payload, timeoutMs)`, `CP.Net.request(name, args, opts)` | shared/net.lua | client; both return `{ ok, data, error }` and never raise (`err.timeout` after timeoutMs, default 15000; `err.no_response` when ox_lib raises). `opts` is the timeout in ms or `{ timeoutMs, latent = true }`: latent sends a reply id (from the `actionResult` ids) and, on a `{ latent = id }` answer, waits up to 60 s more for that latent `actionResult`. The tablet's NUI `request` path always passes `latent = true`; the NUI waits 90 s (`EXPORT_TIMEOUT_MS`, `request(name, args, { timeoutMs })`) for the three exports instead of its 20 s |
| `CP.NpcCombat.*` | shared/npccombat.lua | Config.NpcCombat read at every call (§5.42): `weapon(name)`, `ammo()`, `isAutomatic(name)`, `automatic()`, `automaticsIn(t)`, `weaponsAllowed(list, allowed)`, `capAccuracy(acc)`, `scaleAccuracy(acc)`, `shootRate()`, `firingPattern()`, `ability(a)`, `noCharge()`, `driveByAccuracy(acc)`, `driveByPattern()`, `aiDamage()`, `aiMeleeDamage()`, `reassertAiDamage()`, `officerDefense()`, `noCriticalHits()`, `cancelLethalHeadshots()`, `lethalCancelAbove()`, `enabled()` |
| `CP.Twists.*` | shared/twists.lua | Config.Events.twists read at every call (§5.9): `ORDER`, `known(key)`, `cfg(key) -> { enabled, points, cash }`, `sorted(list)`, `of(run|payload) -> keys` (the `modifiers` list, else the one `modifier`), `has(run, key)`, `caps() -> { points, cash }`, `bonus(list) -> { points, cash, lines }` (shares add, multipliers multiply, both capped) |
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
  itemsBy = 'admin' | 'console' | 'supervisor' | nil, -- custom only: who put this version live (the Mission Builder's
                                  -- publisherRole, else its publish audit row); a run hands out its items only for
                                  -- admin or console, unless Config.Builder.supervisorItems
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
| `hostile_waves` | 60 | `spawns` (location key: list of vec4) · `waves` [{7,7,6}] · `nextWave = { aliveAtMost = 2, afterSeconds = 90 }` · `weapons` · `accuracy` [25] · `armour` [0] · `health` [200] · `behaviour` ('hold'\|'balanced'\|'push') · `surrender = { belowHealth = 0.25, chance = 0.30 }` · `peds` (models) · `boss = { model, label, health, armour, weapon, spawn (location key), surrender = {...} }` (does not scale) · `blockTraffic` [120.0] · `indoor` [false] (the fight is inside a building: the spawn director keeps `Config.Spawning.minDistanceIndoor`, not `minDistance`; Hostage Rescue and the raids' fights) · `stage` [false] (wave 1 is placed ahead of time while the objective before runs, calm and unarmed, and wakes when the fight starts; the raids' fights; see below) · `scene` handled by a following interact_points |
| `protect_rescue` | 15 | `npcs` (location key: list of vec4) · `count` [3] · `peds` · `restrained` [true] · `freeTime` [6000] ms · `target = { label = 'Cut restraints' }` · `safe` (location key vec3) · `safeRadius` [6.0] · `hitPenalty` [50] · `failIfDies` [true] · the hostages appear when this objective starts, through the spawn director (`Config.Spawning.hostagesAt` 'objective'; 'runStart' or `enabled = false`: in `prepare`, when the run moves to In progress, as before) |
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
| `search_area` | 60 | `center` (vec3 key) · `startRadius` [600] · `shrinkTo` [{300,150,50}] · `clues` (list key, 6+) · `clueCount` [3] · `clueProps` (`'witness'` = a witness NPC) · `clueProgress = { label, duration = 4000 }` · `hiding` (vec4 list key, 6+) · `fugitives` [1] · `runDistance` [30.0] · `givesUp = { stun = true, close = { distance = 3.0, seconds = 3 } }` · `escape = { distance = 300, seconds = 30 }` · `cuff = {...}` · each fugitive and clue appears once an officer is near it, through the spawn director (`Config.Spawning`; `enabled = false`: all when the search starts, as before) |

Each block's `server.lua` exposes `defaults(obj)` and `validate(obj, mission, location)` so the
loader and the Mission Builder apply exactly these defaults and guardrails.

A block may also expose `stage(ctx, dt)` (§7.1, `Config.Spawning.stageAhead`): the engine calls it while the objective
before this one runs, so the block can place this objective's people ahead of time. No common field turns it on: a
block that stages decides from its own fields which objectives it stages. `hostile_waves` stages an objective with
`stage = true` (the raids' fights, PLAN S4): wave 1 through the director (`ctx.whenNear`, `ctx.choosePoints` with the
objective's `indoor`, never relaxed), spawned `hidden` (`Runs.spawnPed` opts.hidden: no weapon, armour or fight
settings in the ped or its bag; counted armed) in CP.Npc state `idle`. The whole staged crew wakes (`CP.Runs.arm`, then
CP.Npc state `hostile`; one console line `run <id>: objective 2: <n> staged hostile(s) woke: <why>`) when its `start`
runs, or earlier in `stage` / `onEntityDead` / `onEvent 'damaged'`: one of them hurt (the server's health of him lower
than `stage` read before) or killed, or a participant within `Config.Spawning.stageWakeRange` (2D) of one who is not
nearer to a point of the objective before (its `points`, `targets`, `door` or `checkpoints` location key: the breach
entries) than to him. Awake before `start`, `stage` places nobody more (Refresh and the surrender poll only) and the
client half runs the crew already (`update` data `awake = true`, §7.2). Until `start` no HUD entry and no completion.
The host's client half sets a ped up (`CP.Npc.apply`, first task) only once his bag has caught up: not while it still
says `idle` but the server's list says otherwise, nor while a staged one's bag still says `armed = false` (the
objective's `start` event can arrive before the wake's bag writes); the next 500 ms pass applies the armed cfg.

`flee_arrest` through the director (PLAN S11, `Config.Spawning.enabled`): every associate and inmate gets a point of
his own (`PickSpots`): a list point no person or vehicle of the run stands within 1.5 m of (`SHARE_RADIUS`, objects do
not count), offered in the objective's shuffled order to `ctx.choosePoints` (named by the list key, `wave` = the role,
`since` = the objective's own clock `st.short[role]`, set by the first ask that came back short and cleared by one that
got all). Door mode with `Config.Spawning.associatesAtKnock`: the associates appear only once `st.knocked` (the knock,
or a door-mode death before it), at the next tick, with `indoor = true`, `centre` = the door (so an officer at the door
faces the way in: a point more than `behindAngle` off it is behind him) and `placed` = the associates already out (one
side); each is hostile at once. Scatter mode: only points an officer is near (`ctx.whenNear` per point; nobody near
clears the clock). A list shorter than the people it is for: one `CP.warn` (`<key> has 1 point(s) for 3 inmate(s); the
others come out once a point is free`); a point is used again once its person has left it. After `waveDelayMax` short,
a second ask offers the last resort for what is still missing: the old ring round each point (`REUSE_OFFSET` × lap,
laps = ceil(total / #list)) and, in scatter mode, each escape route's first point (an inmate there runs on along that
route), each checked against the run's people like any point. Any other scatter inmate's route is `RouteFor`: with
`Config.Flee.nearestRoute` (on) the route whose first point is nearest where he appears, routes within `ROUTE_TIE`
(5 m) of as near taken in `st.routeOrder` from his turn on; off, `st.routeOrder` in turn (as before). `Config.Spawning.leaveOutAfter` (and at least
`waveDelayMax`) short while someone of the objective has appeared and every one of them is done: the missing ones are
left out (`st.leftOut`, one `CP.warn` `<n> inmate(s) left out: ...`; `AssocTarget` / `InmateTarget`, the checklist and
the HUD count without them). A door location with no `suspect` point: nobody at the door (`st.noSuspect`, one
`CP.warn`), never the start point. `enabled = false` or `associatesAtKnock = false`: as before (associates at the
objective's start; the ring with `enabled = false`). The suspect a surrender stands at the door step (`MoveToDoor`,
server `SetEntityCoords`) is asked to be placed again there: `CP.Spawn.again` (§5.43).

Worn-out runners (Config.Flee, not a file field): next to its own close rule, each block that owns a runner calls
`CP.Npc.wornOut(netId, near)` with its own nearest-participant distance and, on true, its own surrender (state
`surrendered`, the bag task it returned, Cuff suspect), with no wait: `flee_arrest` for every ped in `'fleeing'`
(armed ones too, before the fire-range rule could turn an armed inmate hostile; a surrendered suspect's feint waits
while wornOut is true), `pursuit` for a suspect in `'fleeing'` in stop mode only (follow mode has no arrests),
`search_area` for a fugitive in `'fleeing'`, `field_contact` for a contact in `'fleeing'` who is not walking off a
consensual contact. The escape rules are unchanged.

field_contact through the spawn director (PLAN S12, Config.Spawning; owner request of 2026-10-19: "make sure they dont
spawn around the player"): a scene (scene mode: its car and every person, all at once) and each parked car (parked
mode: per spot, in any order) appear once `ctx.whenNear` says an officer is within `activateRange` of one of its points
while every officer is further than the objective's `approach` + `sceneOutside` from all of them; an officer standing
closer keeps it waiting (one `CP.log` per point: `spots[1] waits: an officer is 20 m from it, it appears beyond 35 m`),
after `waveDelayMax` the distance drops to `hardMin` (one `CP.warn` when it then appears closer), after `sceneWaitMax`
(0 = never) it appears anyway with one `CP.warn` naming the mission, the place and the point; nobody within
`activateRange` starts no clock. `st.planned` (the cars or the scene's people and car to come) is the HUD's and the
checklist's total while some still wait. The returning driver (a citation or impound) and the thief (the first inspect
of a stolen car) appear in a thread: the game of the officer who acted (else the participant nearest the car) is asked
through the ox_lib callback `crimson-police:client:spawn:walkIn` (§8.1, `CP.Spawn.walkIn` §5.43) for footpath points
`contactRing` from the car, waiting up to `losTimeoutMs`; the first answer point 2D within the ring (1 m slack), within
15 m of the car's height, `contactRing[1]` - 5 m or more from every participant and outside the no-build zones is used,
the next four are the placer's other points (`alt`); no usable answer: 12 points round the car (the angle from the
run's seed, at ring[1], halfway and ring[2] in turn, the car's height), the ones `contactRing[1]` or more from every
participant first, in front of the asked officer's ped first, else the one furthest from them. He faces the car;
`st.walkIns` (the ones on their way) holds the objective open. Once `CP.Spawn.holding(netId)` is false (an officer's
game placed him, or his placement timed out) he is told `walk_to` his car; the driver's outcome (HUD message, then
takes / argues / drives off `ARRIVE_PAUSE_S` 3 s later) waits until he is within 4 m of the car or has walked
`RETURN_WALK_S` + distance / 1 m/s; the thief runs at `thief.runAt` as before. `enabled = false`: everything as before
(scene and cars at once, the driver 14 m and the thief 30 m from the car at a random angle, at once).

pursuit through the director (PLAN S13, Config.Spawning; owner request of 2026-10-19: "i do not want them spawning in
the ground or surronding the officers"). `PlaceFor(ctx, st, i)` returns slot i's point, its console name
(`spawnOffset -200 m, 8 m back`, `spawns[3]`, `route[12]`, `50 m ahead of the start`) and, for spawnOffset, the slot's
base (`OffsetSpot`: `{ p, label, watch }`, kept in `st.offset` once the first car is out, so the next cars queue
behind it). A point of the road route itself (spawnOffset's `AlongRoute`, a loop's waypoint, an open route's first
point, and the queue copies of them) gets `Config.Spawning.vehicleLift` on z (`Lifted`); the file's `spawns` / `spawn`
points are used as written. A spawnOffset < 0 objective on an open route that an earlier pursuit objective of the
mission with a spawnOffset on the same route precedes (`LaterViolator`: Traffic Enforcement's objective 3) counts from
the participant furthest up the road among those within `ON_ROAD` (100 m, 2D) of it (`RoadSpot`: his metres along the
route on the nearest segment) and is placed `secondViolatorUpstream` metres before him (`AtRoad`, never before the
route's first point); `st.watchFrom` = his road point is then where `WatchCruise` judges "passed" instead of the start.
No participant on the road, `secondViolatorUpstream = 0` or the director off: from the start as before. No start: one
`CP.warn` and the spawnOffset branch is skipped (the next ones: spawns, spawn, ahead of the start, the route), never a
player's position. `SpawnVehicle` offers `Candidates` (slot i, then the slots `vehicles + 1` and `vehicles + 2`, none
within `SLOT_TAKEN` 4 m of a car of the objective; labelled `vehicle <i> at <name>`) to `ctx.choosePoints(cands, 1,
{ name, wave = 'vehicle <i>', since = st.waitMs[i], ordered = true })`: the first that passes is used, the rest that
pass go to `spawnVehicle` as `alt` (the placer's other points, §5.43); none passes: no car this tick (SpawnMissing tries
again each tick, the objective waits). `enabled = false` or no `ctx.choosePoints`: slot i at once, as before.

escort through the director (PLAN S14, Config.Spawning; owner request of 2026-10-19: "make sure they dont spawn around
the player"). `SpawnTruck` takes `TruckSpot(ctx, st)`: route[1] (heading to route[2]) and `TRUCK_SPOTS` (4) spots
`TRUCK_STEP` (10 m) apart along the route (`RouteAt`: the route's height there), each z + `vehicleLift`. A spot is
taken while a vehicle the server knows (`GetAllVehicles`, FXServer: a Lua list of handles) or an active participant
(his ped) is within `TRUCK_CLEAR` (6 m, 3D) of it. route[1] free: used. Taken: the truck waits (`tr.waitMs`, one HUD
message `block.escort.msg_clear_start`, one `CP.log`), and after `waveDelayMax` takes the first free spot (one
`CP.warn` naming it); none free: it keeps waiting. The free spots it did not take go to `spawnVehicle` as `alt`. An
ambush car (`ChooseSlot`) offers `CarSlots(ctx, st, w, c)` to `ctx.choosePoints(cands, 1, { name = 'wave <k> car <c>',
wave, since = w.waitMs, ordered = true })`: its own slot (`CarPlacement`, z = the route's height at its nearest route
point when within `ROUTE_Z_NEAR` 15 m, else the point's, + `vehicleLift`), and with `ambushAheadOnly` the slots every
`SLIDE_STEP` (15 m) along the route from its own (`w.s`: the point's metres along the route, + (c - 1) x `CAR_GAP`,
+ `w.slide`, the slide the wave's previous car used) up to `SLIDE_MAX` (300 m) and the route's end, `CAR_SIDE` either
side, facing the truck; a slot is dropped when it is less than `minDistance` ahead of the truck along the route
(`RouteSpot` of the truck on the segments `wp - 2 .. wp + 4`) or within `minDistance` of it on the map (then the
slots start on the first `SLIDE_STEP` mark `SLIDE_AHEAD`, 100 m, or more ahead of the truck, so a slot's console name
stays the same while the truck moves), or within `SLOT_CLEAR` (4 m) of a vehicle. None passes: the car waits
(`w.noSlot`; `SpawnWave` returns false, 'slot' and SpawnMissing goes on with the next wave). `CutWave` gives a wave
still short of slots the cars it has (`w.want = #w.cars`) or drops it (none), one `CP.warn`: at the truck's arrival
for every waiting wave (`CutShortWaves`), and after it for a car that finds no slot (`ChooseSlot`: a wave the spawn
caps held back until then). `enabled = false`: route[1] at the road's height at once and the own slot at the point's height + 0.5 m at
once, as before; `ambushAheadOnly = false`: the own slot only, through the director.

search_area through the director (PLAN S16, Config.Spawning; owner request of 2026-10-19: "make it be progressive",
"make sure they dont spawn around the player"; before, every fugitive and clue appeared when the search started,
276-560 m from the officers, beyond the 424 m a player's game simulates). `start` and each `tick` call `SpawnMissing`,
which plans the clues (`PlanClues`, `cl.name` = `clues[5]`) and the hiding order (`st.order`) once, then `SpawnNear`
(in a pcall, `st.spawning` cleared always). Fugitive i has his own spot from the start (`Slot(i)`: point `order[k]`,
the `REUSE_OFFSET` ring per lap as before, named `hiding[3]`); `FugitiveAnchor` counts a fugitive who has not appeared
as hidden there, so the circle shrinks towards his spot. `SpawnFugitiveNear`: once `ctx.whenNear(spot)`, his spot
(`own = true`, `centre` = his spot, so it is never behind an officer) and the `OtherSpots` (no fugitive's own spot,
none a fugitive appeared on, inside the current circle, an officer near it) go to `ctx.choosePoints(cands, 1, { name =
'the fugitive', centre, ordered = true })`: no `wave`, so the distance never relaxes (minDistance, 40 m, from every
officer). His own spot passes: he appears there, the spare points as `alt` for the placer. It does not: he waits
(`st.fugWait[i]`, counted while an officer is near); after `waveDelayMax` he takes the other spot the director chose
instead, one `CP.log` (`fugitive 1 hides on hiding[7] instead of hiding[1]: an officer stood 30 m from it for 20 s`).
Each clue (`ClueReady`): once `ctx.whenNear(cl.coords)`, `ctx.choosePoints({ { coords, label = cl.name } }, 1, { name =
'clue <i>', wave = 'clue <i>', since = cl.waitMs, unseen = true })`: 40 m from every officer, or closer where no
officer's game can see it (§5.10 `opts.unseen`); after `waveDelayMax` `hardMin` (20 m) in sight. What appeared stays
until it is checked, lost or the run ends. `st.slots[i]` marks the fugitives made, `st.count` counts them; the client
offers "Check clue" only on a clue that is there (`netId`). `enabled = false`: `SpawnAll`, everything at once when the
search starts, as before.

protect_rescue through the director (PLAN S15, Config.Spawning; owner request of 2026-10-19: "make it be progressive").
With `hostagesAt = 'objective'` (shipped) `prepare` makes nothing; the hostages appear when the objective starts
(`start`, then each `tick` for the ones still missing): once `ctx.whenNear` says an officer is within `activateRange`
of the middle of their points, `SpawnDirected` offers every free spot (`Slot(i)`: hostage i on point `order[k]`, the
`REUSE_OFFSET` ring per lap as before, named `hostages[3]`) to `ctx.choosePoints(offer, #offer, { name = 'the hostages
(<key>)', wave = 'hostages', since = st.waitMs, centre, indoor = true })`: minDistanceIndoor (15 m) from every
officer, never behind one (no line-of-sight ask: every spot is asked for). The spots it refuses wait (`st.waitMs`,
counted while an officer is near); after `hostagesWaitMax` (10 s; 0 = never) the rest appear on their spots anyway
with one `CP.warn` naming the mission, the place, the nearest officer's distance and the setting (they are tied up and
unarmed, and the rescue cannot go on without them). `st.slots[i]` marks the spots used, `st.spawned` counts them. A
location with no hostage points spawns nobody, with one `CP.warn` (never the start point, as before). `hostagesAt =
'runStart'` or `enabled = false`: in `prepare` on every spot in order, with the retry thread, as before
(`spawnsInPrepare` returns true then).

Evidence field_contact accepts: `{ type = 'action', netId, action, phase = 'begin'|'finish' }` (from the plain
event `crimson-police:server:custody`), `{ type = 'decide', netId, choice, offence }` (from the action
`server:contactDecide`), `{ type = 'cuffed', netId }` (CP.Npc), `{ type = 'aim' | 'stunned', netId }` (client
reports; `stunned` goes through `CP.Npc.stunCheck`), and the engine's entity events
`{ type = 'handed_over' | 'impounded' | 'removed', netId }` (`CP.Runs.entityEvent`). The block keeps the Contact
panel in `ctx.state.contact`; `CP.Runs.view` returns it
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
                                  -- + staged = true (its stage hook placed people ahead of time, ctx.staged),
                                  --   stageOff = true (its stage hook raised an error: never called again),
                                  --   staging = the tick's thread while its stage hook runs (holds its start)
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
  npcCombat = true,               -- false (create opts.npcCombat = false): client:start says npcCombat = false (§5.42)
  removedVehicles = { [netId] = { src, via } },            -- vehicles removed from outside (sc-police /imp)
  holdBodies = nil | { roles, max }, held = { netId, ... },  -- bodies kept for Process the scene (FIFO past max)
  fastClockAt = nil | ms,         -- CP.Runs.pauseFastClock: the fast-completion clock stopped
  failReason = nil | 'reason.*',  -- why the case failed (a decision, a removed vehicle ...)
  spawning = nil | { [objectiveIndex] = { clocks = { [wave] = os.time() of its first ask }, said = { [line] = true } } },
                                  -- the spawn director's memory (CP.Runs.choosePoints): wave clocks, console lines said
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
| `downed_case` (a downed officer of a live crime, `Config.RealSuspects.downed = 'keep_earned'`; the lines earned so far, scored in V13) | completed | **no** | yes | yes (with `downed` in keepPayTierFor) |
| `downed_kept` (the same on a volunteer-suspect run; today's failed credit) | failed | **no** | yes | yes (with `downed` in keepPayTierFor) |
| `disconnected` | failed | yes | yes | no |
| `completed` / `time_limit` / `mission_failed` (still in at the end) | completed / failed | no | yes | — |
| `vehicle_removed_external` (a run vehicle removed by someone outside the run, or vanished with nothing recorded) | abandoned (not counted: no points, cash or abandon penalty) | **no** | **no** | — |

"Keeps pay tier" = `Config.Rescale.keepPayTierFor` (read from config, not hard-coded; its `downed` entry also covers
`downed_case` and `downed_kept`). When a
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
   `accepted`, location reserved, B locked, the chosen twists that fit the drawn mission kept (`run.modifiers`, a
   random one added while `modifierChance` > 0), `client:start` sent to each participant,
   `CP.Route.begin(run, src)` for each, start timeout armed, items given.
2. `CP.Route` detects arrival → `CP.Runs.markArrived(run, src)` → `CP.Alerts.set(src)`; the first
   arrival moves the run to `in_progress`: tier from active participants (or `test.forcedTier`),
   `client:inProgress`, every block's `prepare` (state only: a prepare that made entities of its objective gets one
   `CP.warn` per block until the resource restarts, `WarnOnce('prepare:<block>')`, unless the block's
   `spawnsInPrepare(ctx)` returns true), objective 1 `start`, timer starts.
3. Blocks call `ctx.complete()` / `ctx.fail(reason)`; the engine advances objectives. The last
   objective done → `CP.Runs.endRun(run, 'completed', 'completed')`. Timer out →
   `endRun(run, 'failed', 'time_limit')` unless the block's `onTimeout(ctx)` returns `'completed'`.
   Stage ahead (`Config.Spawning.stageAhead`, under the director's `Config.Spawning.enabled`): while objective i is
   current, each 1 s tick, after its own `tick` and the time limit, calls `stage(ctx, dt)` of objective i + 1 when its
   block has one: once a tick, only while i + 1 is still pending (never in the tick i completes, never after i + 1
   started, never for i + 2), only in progress (after every `prepare`). Its ctx is objective i + 1's own (spawns are
   tracked under i + 1, `ctx.state` is the table its `start` gets), so an end, a failure or the last participant
   leaving deletes what it placed like every run entity, and `stop` reaches it at the end like every prepared
   objective. A `stage` that returns true marks the objective staged (`objectives[i + 1].staged`, `ctx.staged`, one
   `CP.log` line); one that raises an error is logged, never called again for that objective (one `CP.warn`), and the
   objective starts as before. Read live: switched off mid-run, nothing more is staged and what was placed stays.
   `stage` may wait (each spawn waits for its entity, and every run ticks in its own thread), so objective i can
   complete meanwhile from an officer's event: the engine then holds the start of i + 1 until `stage` returns (at
   most `TICK_STUCK_MS`, 30 s), so its `start` gets `ctx.staged` and everything `stage` placed, and nothing is placed
   after `start`. One that started anyway (held longer, or started from inside the hook) is not marked staged (one
   `CP.warn`).
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
  — reused for `Config.Limits.playerInfoCacheMs` (1000; 0 = one `GetPlayer` per call), cleared at once by every
  qbx_core event below plus `QBCore:Player:SetPlayerData`, `playerDropped` and a qbx_core stop/start; each caller
  gets its own copy of the top level and `job` (`metadata` is read only). `getPlayer` is never cached.
- S `getByCitizenId(citizenid) -> src|nil`
- S `getOnlinePlayers() -> { src, ... }` — ascending; one `GetQBPlayers` copy at start, when qbx_core starts and every
  60 s, kept by `PlayerLoaded` / `OnPlayerUnload` / `playerDropped` in between (`playerInfoCacheMs = 0`: every 1 s and
  after each of those events)
- S `knownJob(src) -> jobName|nil` — the primary job qbx_core last reported, kept only by `QBCore:Server:PlayerLoaded`,
  `QBCore:Server:OnJobUpdate`, `QBCore:Player:SetPlayerData` (qbx_core's UpdatePlayerData: its SetPlayerData export,
  SetJob, the group functions), every `getInfo` and the `GetQBPlayers` copy of `getOnlinePlayers` (at start and when
  qbx_core starts); cleared on unload, drop and a qbx_core stop. nil = not known. It never feeds `CP.Access`'s onLost.
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
- S `on(kind, fn) -> bool` (real suspects, V3) — listen-only `hospital:server:RespawnAtHospital(hospitalIndex)`: a
  second, read-only handler that calls each `'respawn'` listener with `(src, hospitalIndex)` (a whole number 1..255;
  anything else is dropped). It returns at once while no listener exists or `CP.Opponents.active()` is not true (no
  native read), rate-limits `'scp:respawn'` 6 a second per sender (dropped silently), calls each listener inside
  pcall (one error line a minute) and never yields; it never triggers, cancels or answers a hospital:* event and
  never touches `hospital:server:RevivePlayer`. Unknown kind or no function → false.

**CP.Banking** — modules/integrations/renewed_banking (S only)
- `recordDeposit(citizenid, amount, message, issuer, receiver, transId)`
- `withdrawSociety(account, amount) -> boolean`
- `recordSocietyWithdraw(account, amount, message, issuer, receiver, transId)`
- `societyBalance(account) -> number|nil`
- Full admin control (economy): `depositSociety(account, amount) -> boolean` (`addAccountMoney`), `recordWithdraw(citizenid,
  amount, message, issuer, receiver, transId)` (a personal `withdraw` entry: a clawback), `recordSocietyDeposit(account,
  amount, message, issuer, receiver, transId)` (added funds, a refunded clawback), and `findTxn(transId, { citizenid,
  account }) -> { personal = entry|nil, society = entry|nil }` with `entry = { found, amount, type, time }`: reads
  `player_transactions` (id = citizenid) and `bank_accounts_new` (id = account) through the real oxmysql
  (`CP.Storage.realMySQL` with the database off), read only, and returns only the entry with that `trans_id`, never the
  rest of the history. Not found proves nothing (Renewed-Banking writes history only for a cached player).
- **CP.Qbx** (economy): S `getMoney(src, account) -> number|nil` (`PlayerData.money[account]`; bank may be below 0),
  `removeMoney(src, account, amount, reason) -> true | false | false, 'error'` (`player.Functions.RemoveMoney`; `'error'`
  = it raised and the balance may have changed).

Parity-plus additions to the integrations:
- **CP.Qbx** S `plateOwned(plate) -> bool|nil` — `SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1`, read-only,
  always the real oxmysql (`CP.Storage.realMySQL` with the database off); nil on error (the caller then uses the
  reserved plate pattern alone). Used only to reroll a mission plate.
- **CP.Qbx** (full admin control) S `getInfo(src)` gains `license` (`PlayerData.license`); `licenseOf(citizenid) ->
  license|nil` (the online player's, else `SELECT license FROM players WHERE citizenid = ?`), `characterExists(citizenid)
  -> bool|nil`, `citizenidsOfLicense(license) -> { citizenid }` (`SELECT citizenid FROM players WHERE license = ? LIMIT
  20`), `userLicenses(license) -> { license, ... }` (this one first, then the `license` and `license2` of Qbox's
  `users` row that has it: `SELECT license, license2 FROM users WHERE license = ? OR license2 = ? LIMIT 5`; just `{
  license }` without that table). Read only, always the real oxmysql (`CP.Storage.realMySQL` with the database off),
  never a cp_ table in the same statement; nil or `{}` (one error line a minute) when the lookup fails.
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
- **CP.ScPolice** S `on(kind, fn) -> bool` (real suspects, V3) — listen-only facts from a second, read-only handler for
  each of sc-police's `police:server:CuffPlayer(playerId, isSoftcuff)` → `'cuff'` (officerSrc, targetSrc,
  isSoftcuff == true), `UncuffPlayer(playerId)` → `'uncuff'` (officerSrc, targetSrc), `CuffBreakAlert(officerId)` →
  `'cuffBreak'` (suspectSrc, officerSrc), `EscortPlayer(playerId)` → `'escort'` (officerSrc, targetSrc),
  `JailPlayer(targetId, jailTime)` → `'jail'` (officerSrc, targetSrc, jailTime raw: the listener clamps it),
  `BobbyPinResult(success)` → `'bobbyPin'` (pickerSrc, success == true; sc-police ignores a result with no pending
  attempt, this handler does not) and `SeizeCash(playerId)` → `'seizeCash'` (officerSrc, targetSrc). Every handler:
  `local src = source` first; returns at once while no listener of its kind exists or `CP.Opponents.active()` is not
  true (CP.Opponents arrives in V4: until then nothing runs), so with no case open it reads no native; then
  `CP.Net.rateOk(src, 'scp:' .. kind, 6, 1000)` (dropped silently); then the sender and ids must be whole numbers
  1..65535 (else dropped); each listener runs inside pcall (one `CP.err` a minute per kind), inside the event, and must
  not yield. `police:server:SetHandcuffStatus` is never registered (cuffs come from the qbx `ishandcuffed` metadata
  only). Unknown kind or no function → false; the same function twice is kept once.

### 5.2 CP.Access — modules/access
- S `departmentForJob(jobName) -> deptKey|nil`
- S `department(key) -> sanitised dept` `{ key, label, short, jobs, supervisorGrade, societyAccount, theme = { primary, accent, background, surface, text }, logo = { url|nil, watermark, opacity, size, grayscale } }` (invalid colours fall back to the Crimson-Police default with one console warning; `text` auto-picked with `CP.U.contrastText`; `logo.url` = `https://cfx-nui-<CP.resource>/logos/<file>` or the configured https url)
- S `departments() -> { dept, ... }` sorted by key
- S `getOfficer(src) -> officer|nil, errKey` — on-duty, active job in a department, not suspended (Crimson-Police or SC-Dispatch). errKeys: `err.not_police`, `err.not_on_duty`, `err.suspended`, `err.suspended_dispatch`
- S `maybeOfficer(src) -> boolean` — a pre-filter for loops over every online player, with no Qbox lookup: false only
  when `CP.Qbx.knownJob(src)` is in no turned-on department (so `getOfficer` would refuse); an unknown job is true.
  Call `getOfficer` for the full check. Loops never call `exports.qbx_core:GetPlayer` per player (loop rule 8).
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

Full admin control (P0 seams; §5.37):
- S `getOfficer(src)` also refuses a retired officer (`cp_officers.retired_at` set): `err.retired` (cached 15 s like the
  suspension).
- S `isRetired(citizenid) -> bool`; `dispatchSuspension(citizenid, jobName?) -> { suspended, available }` (view only).
- S `suspend(citizenid, days, actorSrc, reason, opts)`: `opts.untilTs` suspends until that exact moment (future, at most
  3650 days away; days is then ignored).
- S `refreshOfficerRow(src)` also writes `cp_officers.license` (never clears a known one).
- One player has a `license:` and usually a `license2:` identifier, and Qbox stores each character under one of them
  (qbx_core Login accepts either; a new character gets `license2` first; `players.license` is never rewritten, so a
  QBCore-era character keeps `license:`). `GetPlayerIdentifierByType` returns the first identifier that starts with the
  text given, so every lookup passes the type with its colon (`'license:'`, `'license2:'`, `'fivem:'`).
- S `licenseOfSrc(src) -> license|nil` (`CP.Qbx.getInfo(src).license`, else `GetPlayerIdentifierByType(src,
  'license:')`), `licensesOfSrc(src) -> { license }` (that one, the `license:` and the `license2:` identifier, no
  repeats; `{}` for the console), `licenseOf(citizenid) -> license|nil` (`cp_officers.license`, else
  `CP.Qbx.licenseOf`; cached 15 s), `selfCitizenids(src) -> { citizenid }` (the current character first, then every
  cp_officers row and Qbox character of any of `licensesOfSrc`; the console has none), `sameUser(a, b) -> bool` (the
  same text, or one Qbox `users` row has both: `CP.Qbx.userLicenses`; the record move's license check).
- Hook `admin:changed { citizenid }` drops that officer's suspension, retirement and license caches at once.

Full admin control, System (P5):
- Turned-off departments (`Config.Departments.<key>.enabled = false`): `department(key)` and `departments()` still
  return them (`enabled = false` in the sanitised record), so their pending and held pay still finds the society
  account; `departmentForJob(job)` leaves them out, `offDepartmentForJob(job) -> deptKey|nil` names the one that lists
  the job, and `getOfficer` then refuses with `err.department_off`.
- S `explain(src, via?) -> { ok, error?, steps = { { check, ok, vars? } }, via, src, citizenid, name, job, department }`:
  the opening checks in order (job, department on, duty, suspended, SC-Dispatch suspension, retired, arena, the way);
  the verdict is `getOfficer` then `CP.Tablet.checkAccess` (the opening code itself), so it never disagrees with a real
  open attempt.

### 5.3 CP.Permissions — modules/permissions (S)
- `can(src, action, ctx) -> boolean, errKey` — admin: always true for admin and supervisor actions. Supervisor: `CP.Access.isSupervisor(src)` and `Config.Permissions.supervisor[action] == true`. Admin-only actions (never allowed for supervisors whatever the config): `setMissionPayout`, `clearPayout`, `manualAward`, `handleFailedDispute`, `voidAnyRun`, `seasons`, `bountyOverride`, `suspend`, `reloadMissions`, `testRun`, `openAdmin`. Also `viewMissionList` (supervisors and admins). errKey `err.no_permission`.
- `actionsFor(src) -> { actionName, ... }` (for the session)
- `tookPart(citizenid, runUuid) -> boolean` (any cp_mission_runs or cp_mission_runs_archive row of that run for that
  citizenid; a failed lookup counts as taking part)
- Full admin control: 18 more admin-only keys, none of which a `Config.Permissions.supervisor` switch can give a
  supervisor: `officerRecords`, `pointsAdjust`, `bulkVoid`, `restoreRun`, `progression`, `antiFarmOverride`, `liveRuns`,
  `editBuiltins`, `missionAdmin`, `boardsAdmin`, `payments`, `rewardsAdmin`, `deptFunds`, `departmentsAdmin`,
  `storageAdmin`, `playerSupport`, `recordMove`, `cleanup` (also listed in modules/admin's ADMIN_ONLY mirror for the
  Permissions screen). `isAdminOnly(action) -> bool`, `adminOnlyKeys() -> { key }` (the 29, in order).
- `probe(src, name)` — a player who is not an admin asked for an admin-only action: `can` (an admin-only key),
  AdminKit's guard and `Kit.callback` (the action or callback name) call it before their unchanged refusal. One
  `CP.warn('security', 'player <src> (<name>) sent admin-only <name> while not an admin')` (kept in CP.Problems) per
  player and name a minute (`CP.Net.rateOk`), at most `Config.AntiCheat.adminProbeLines` (5) lines a minute per player;
  0 = none; src 0 or not a player never counts. No officer or supervisor path asks an admin-only key of a non-admin:
  CP.Testing asks `builderEdit` alone for draft tests and `test:state` (every admin passes it), builder overrides check
  `actor.isAdmin` first.
- `canReviewRun(src, runUuid) -> boolean, errKey` — false when the reviewer, or any character of their licenses
  (`CP.AdminKit.selfRun`), took part (`err.own_run`)

### 5.4 CP.Tablet — modules/tablet (owns the NUI)
Server:
- callback `getSession(args)` → Session (§9.2). `args.ui` = 'officer'|'supervisor'|'admin'.
- `notify(src, kind, key, vars, opts)` → client toast (`kind` = 'info'|'success'|'warning'|'error'); `opts = { title = key, duration = ms }`
- `notifyMany(srcs, kind, key, vars)`
- `push(src, topic, data)` → NUI `{ type = 'push', topic, data }` (live screen updates)
- `openAdmin(src)` → opens the Admin UI (called by modules/admin for `/CrimsonPoliceAdmin`)
- Logo check at start (`LoadResourceFile` of each department's logo file, once the saved settings are loaded) and one
  warning per logo the NUI reports as failed (`logoFailed` client action).
- `logoFor(dept) -> { url, watermark, opacity, size, grayscale } | nil`: the logo a department's tablets show now (the
  session logo and the Admin UI → Departments preview). Clients load `https://cfx-nui-<res>/logos/<file>` only from the
  files FXServer packed at the start, so a `logo.file` that was not one of the start's department files (an upload with a
  new name, the first logo of a department added in game) keeps the department's start logo (or none) until the
  restart, and `logoFailed` never blames such a pending file.
Client:
- `/CrimsonPolice` command (`Config.Tablet.command`), optional keybind (`Config.Tablet.keybind`, via
  `RegisterKeyMapping`), optional ox_inventory item (`Config.Tablet.item`), export `OpenTablet()`.
- `open(ui)` / `close()` / `isOpen()`; the Officer/Supervisor UI plays the tablet prop
  (`Config.Tablet.prop`) and animation; closing removes the prop.
- `playerDown() -> boolean`: dead or in last stand (qbx metadata, or a dead ped). No CP screen holds the NUI focus
  while it is true (the tablet closes, the test panel and its prompt let go).
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
- S `itemOk(src)`: requireItem again for `server:acceptType` and `server:claimMissionCall` (`err.no_tablet_item`):
  true when requireItem is off, when the last passed way was a desk and the ped is still in that desk box grown by
  `Config.Tablet.deskDistance` + 2 m, or when the item is in the inventory now.
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

Full admin control (P0 seams):
- S `registerNavCount(key, fn(src, officer|nil) -> number, { adminOnly })`: a sidebar count another module owns.
  `adminOnly` counts (`adminReview`, `adminDisputes`, `adminPayments`, `adminLive`) are computed and sent for admin
  players only, never to an officer or supervisor; others for officers. `navChanged(src)` schedules a `nav` push.
- S `pushAdmins(topic, data) -> n` and `notifyAdmins(kind, key, vars) -> n`: to every online admin (`GetPlayers` +
  `CP.Access.isAdmin`), never anyone else (the `adminjob` progress, admin screens); `onlineAdmins() -> { src }`.
- S the Session gains `maintenance` (`CP.Maintenance.view()`, §5.37).
- C on `settings:changed`, when `Config.Labels` changed, the NUI gets `{ type = 'locale', locale = CP.Locale.all() }`
  (§9.1) so an open tablet shows the new names at once.

### 5.5 CP.Schedule — modules/schedule (S)
All times are server local time; the "day" starts at `Config.Time.resetHour`.
- `now() -> os.time()`
- `dayKey(ts?) -> 'YYYY-MM-DD'` (the reset-adjusted day), `dayStart(ts?) -> ts`
- `weekStart(ts?) -> ts` (resetHour on `Config.Leaderboard.weekStartsOn`), `weekKey(ts?) -> 'YYYY-MM-DD'` of the week start
- `monthStart(ts?) -> ts` (1st of the month at resetHour)
- `weekday(ts?) -> 'monday'..'sunday'` of the reset-adjusted day
- `sqlTime(ts) -> 'YYYY-MM-DD HH:MM:SS'`
- `onDaily(fn(dayKey))`, `onWeekly(fn(weekKey, prevWeekStartTs))`, `onMonthly(fn(monthStartTs))` — fired once when the boundary passes (checked every 30 s; never fired just because the resource started)
- `onDailyJob(fn(dayKey))` — a long job for each daily reset (the daily backup): after the daily listeners, the jobs run
  one after another in one thread and the retention job runs when the last one has returned, so the reset listeners,
  the weekly and monthly ones and the next boundary check never wait for them (a reset that comes while the previous
  reset's jobs still run is skipped with a warning)
- Retention job at each daily reset: move `cp_mission_runs` rows older than `Config.Retention.runArchiveMonths` months into `cp_mission_runs_archive` (INSERT … SELECT then DELETE, only when > 0); delete `cp_audit` rows older than `Config.Retention.auditDays` (0 = off).
- Full admin control (economy): the archive never moves a row whose money or item rewards are unfinished
  (`cash_status` held, pending or paying; a `cp_item_rewards` row held, pending or giving), and deletes a live row only
  when its archive copy matches on cash status and amount paid too; the job also purges `cp_admin_requests` older than
  7 days and `cp_settings_history` with `Config.Retention.auditDays`. It waits up to 60 s for the shared busy lock
  (`CP.AdminKit.waitIdle`, then skips with `skipped = 'busy'`) and holds it (`cleanup`) while it works; while
  `CP.Maintenance` holds a lock the retention job and every boundary check wait (`skipped = 'maintenance'`).
  `cleanupView() -> CleanupView` (§9.5: last result `{ at, by, archived, kept, auditDeleted, requestsDeleted,
  historyDeleted, durationMs, error, skipped }`, `running`, `nextRunAt`, the retention values). Callback
  `admin:getCleanup` and action `server:admin:runCleanupNow { reason }` (§8.4.4).

### 5.6 CP.Missions — modules/missions
Server:
- `loadAll()` — reads `missions/builtin/index.lua` (`return { 'id', ... }`) and each
  `missions/builtin/<id>.lua` with the mission file reader (below; read as data, never run), then asks
  `CP.Builder.loadPublished()` for custom missions; normalises and validates each (blocks' `validate`),
  keeps the valid ones, warns about the rest, then broadcasts.
- `reload() -> summary` (admin `/CrimsonPoliceAdmin reload`; also calls `CP.Builder.onReload()`
  for hand edits), `get(id)`, `all() -> { [id] = def }`, `list() -> sorted list`,
  `byType(type) -> list` (excludes the boss), `isEnabled(id)` (published, not archived, not in
  `Config.DisabledMissions`), `normalize(def, meta) -> def|nil, err`, `serializeForClient(def)`
- `register(def)` / `unregister(id)` — used by the builder for publish/archive without a reload.
- `parse(luaSource, chunkName) -> def|nil, err` — reads one mission file's source as the loader does and returns the raw definition (used by the builder for custom files and hand-edit reloads, and by CP.Testing).
- The mission file reader (shared/utils.lua): mission files are data and are never run. FXServer builds its Lua
  with `LUA_SANDBOX`, so its `debug` table has only getinfo, getmetatable, setmetatable, getupvalue and traceback
  (no `sethook`): text that runs could not be stopped, and mission text that reached a string method would reach
  CfxLua's own C functions (`string.blob` allocates any size in one call). So no mission text is executed:
  - `CP.U.parseMissionFile(text, chunkName) -> def|nil, err` — the table of the file's single
    `RegisterMission(...)` call. `CP.U.readMissionCalls(text, chunkName) -> list|nil, err` (every call's value) and
    `CP.U.readMissionReturn(text, chunkName) -> true, value|nil, err` (`return <value>`, for index.lua).
  - Accepted: comments; `RegisterMission(<table>)` or `RegisterMission <table>`, `;` between statements; values
    nil, true, false, numerals as Lua's lexer cuts them (hex, exponents, any number of unary `-`, converted by
    `tonumber`), quoted strings with every Lua 5.4 escape and long strings `[==[...]==]` (line breaks as Lua reads
    them), tables (`name = v`, `[k] = v` with a string, number or boolean key, positional), and `vec3`/`vector3`
    with exactly 3 numbers or `vec4`/`vector4` with exactly 4, built by the runtime's own constructors. A UTF-8 byte
    order mark is skipped. A key given twice in one table is refused.
  - Refused with `<chunk>:<line>: <reason> near '<text>'` (the text clipped to 40 printable characters): any other
    name, an operator, a call, `local`, `function`, CfxLua's extra syntax (backtick hashes, `+=`, `/* */`, `?.`,
    `{ .a }`, `local a in t`) and every malformed token. The loader prefixes `syntax error: `; its own messages stay
    (`the file is empty`, `never calls`, `exactly one call is allowed`, `RegisterMission expects a table`).
  - Bounded (`CP.U.missionFileLimits`): 1,048,576 bytes of text (checked before reading), 100,000 values, tables 32
    deep. Time and memory are linear in the text; the reader never touches the string metatable, the GC or `_G`,
    and reads the text with its own copies of `string.byte`, `sub`, `find` and `match`.
  - Every path that turns a file into a definition uses it: built-ins and index.lua, custom files, edited built-ins
    (overrides), the Builder's publish read-back and draft/backup files, `ShippedOf` (Edit in Builder, baselines),
    `admin:previewImport` (the reason goes back to the Admin UI with `err.import_parse`), CP.Testing.
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

Full admin control (§8.4.2): `loadAll` asks `CP.Builder.loadPublished()` first (its file sync runs before), then
`CP.Builder.loadOverrides()`, and swaps each built-in for its override under the same id (`source = 'builtin'`,
`overridden = true`, `overrideVersion`, `baseHash`, `shippedHash`); a broken override is logged, listed in
`overrideFailed` and the shipped mission plays. `Config.MissionTweaks` apply on top of the override. The summary keeps
`overridden`, `overrideFailed`, `warningTexts` (the first 200), the Builder's sync result (`builder`) and `at`.
`loadSummary()` (callback `admin:getMissionLoad`; Config health line `missions`), `refreshBuiltin(id)` (one built-in
loaded again after an override changes; runs going keep their definition), `rawOf(id)`, `checkTweak(id, tweak) ->
ok | false, errKey, reason` (the loader's answer for a `MissionTweaks` entry; CP.Settings asks it on every change made
in game, never at boot), `trial(patch) -> { checked, failed }` (A14: every mission through the loader with a settings
patch on Config, put back before it returns) and `stats(args)` (callback `admin:getMissionStats`: counts and sums in
SQL, rates and averages in Lua, 60 s cache per filter).

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
- Handles `server:acceptType` (payload = type key or `'weekly_boss'`, or `{ missionType, twists }`): leader only; checks role,
  duty, unit, cooldowns, `CP.Calls.isOnCall`, hourly cap, `CP.Runs.capsOk`, `CP.Operations.isLocked`,
  `CP.Events.bossAvailable`, `CP.Alerts.foreignFlag` for every member (`err.in_arena`), then the twists
  (`Draw.checkTwists`); then `CP.Units.lock(unit)`, the ready check (with the twists), draw, `CP.Runs.create({ twists })`.
- Twists (PLAN M8b): `twistOffer(key, defs)` (CP.Events.twistOffer; each board card's `twists`), `twistCaps()`
  (BoardData `twistMax`), `checkTwists(typeKey, officers, raw) -> keys | nil, errKey` (against the type's pool for
  those officers; `{}` without twists). `accept(src, typeKey, opts)` takes `opts.twists`; its reply adds `twists`.

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

Full admin control: the accept check (`check`, `CheckAccept`) refuses `err.maintenance` while
`CP.Maintenance.active()`. An edited built-in is drawn under the built-in's id like the built-in it replaces.

### 5.8 CP.Scaling — modules/scaling (S)
- `tierFor(n) -> row` (first `Config.Scaling` row with `maxParticipants >= n`, else the last)
- `tierByName(name) -> row`, `lower(a, b) -> row` (the lower tier), `label(name) -> text`
- `scaleCount(base, tier) -> int` (`CP.U.round(base * tier.count)`)
- `apply(mission, tier) -> objectivesCopy` — deep copy of `mission.objectives` with every
  `mission.scaling` path scaled (numbers and lists of numbers; `{ path, max }` clamps)
- `combat(baseAccuracy, baseArmour, tier, run) -> accuracy, armour` (+ tier; + `Config.Events.armoredArmour` when the run's modifier is `armored_hostiles`)

Parity-plus: `combat()` adds `Config.NpcDifficulty[preset].accuracyAdd/armourAdd`; `feel() -> { healthMult,
surrenderMult, fleeMult }` for the blocks (fleeMult stretches CP.Npc's flee clock, §5.11). Presets change how NPCs feel, never points or cash. Config.NpcCombat:
the accuracy `combat()` returns is then `CP.NpcCombat.scaleAccuracy` (× accuracyScale, at most accuracyMax); a
boss's accuracy goes through `ctx.combat` too (its armour stays the file's).

### 5.9 CP.Events — modules/events (S)
- `typeOfTheDay(dayKey?) -> typeKey|nil` (seed = `CP.U.hash(dayKey)`; nil when `Config.Events.typeOfTheDay` is false)
- `rollModifier(run) -> key|nil` — a random twist on top of the chosen ones: `Config.Events.modifierChance` (0, as
  shipped, never rolls); never for operations, the boss or tests; only an enabled twist that fits `run.mission` and is
  not on the run yet
- `modifiers() -> { key = { label = locale key, armedOnly, enabled, points, cash } }` (the Today screen)
- Twists the officers choose (PLAN M8b; `CP.Twists` holds the list and the bonus maths):
  `twistFits(key, def) -> bool` (Armored Hostiles only where a block's `armedCount` is above 0, Time Crunch only with a
  time limit, none on the boss); `twistOffer(missionType, defs) -> { { key, label, desc, points, cash, some? } }`
  (every enabled twist that fits a mission of the pool; `some` = not all of them; `{}` for `weekly_boss`);
  `checkTwists(raw, missionType, defs) -> keys | nil, errKey` (`err.invalid_payload`, `err.twist_unavailable`);
  `fitTwists(run, chosen) -> kept, dropped` (after the draw; nothing on tests, operations or the boss)
- `bossAvailable(src, officer) -> ok, reasonKey` — enabled, weekday in `Config.Events.weeklyBoss.days`, not used this week (any boss row this week except end_reason real_call/force_recall/cancelled)
- `bossCard(src) -> card|nil` (§9.4)

Full admin control (P3, §5.39):
- `typeOfTheDay(dayKey?)` answers today's admin override first; `rolledTypeOfTheDay(dayKey?)` is the seed's pick.
  `todOverride() -> { day, type ('none' = none today), by, reason, at } | nil`; `setTodOverride(choice, meta) -> ok,
  errKey` (`choice` a type, `'none'` or `'auto'`/nil = back to the roll); `todDay()`. The choice lives in memory and in
  its `cp_audit` row (action `todOverride`, target = the day key, new_value = the choice), which a restart reads back:
  a backup restore never replaces cp_audit, and another day's override is ignored, so it always ends at the daily
  reset. No resource KVP.
- `rollModifier(run)` skips every twist with `Config.Events.twists.<key>.enabled = false`; `modifiers()` adds `enabled`.
- The weekly attempt: a boss row counts only while `voided = 0`, and `cp_officers.boss_extra = { week, n }` adds `n`
  attempts for that week. `bossUsage(citizenid) -> { used, extra, left, week }`; `forgetBossUsage(citizenid?)`. The
  `usedCache` entry is dropped on `admin:changed { citizenid }`, and the whole cache on `row:voided` / `row:restored`.

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

Full admin control (P3, §5.39):
- `create` refuses `err.maintenance` while `CP.Maintenance.active()` (checked at the start and again right before the
  run is registered), for every kind of run: normal, test, operation and boss.
- `cancelRun(run, endReason = 'cancelled', opts = { src, reason }) -> ok, errKey`: an admin's End run / End test.
  Participants who are down leave the way every end handles them (`CP.Downed.handle`, Hard rule 18); everyone else
  leaves together as Abandoned with `endReason` (no cooldown, no points, no pay) through the same path as `endRun`
  (`CleanupRun`: objectives stopped, entities deleted, the reservation released, items removed, flags cleared, routes
  stopped, rows written, `run:ended`). A Cross-Department Mission's run is ended through `CP.Operations.cancel(src,
  reason)`, so `cp_operations` says cancelled.
- `addTime(run, seconds, maxTotal) -> ok, totalAdded | false, errKey`: only while the timer runs
  (`err.live_timer_not_running`; before that `adjustTimer` would raise `run.timeLimit`); `run.timeAdded` keeps the
  total (`err.live_time_max` past `maxTotal`); `run.timeLimit` never changes, so `fast_finish` is judged on the
  original limit.
- `clearCooldowns(citizenid, scope, key)`: after the `cp_officers.cooldown_clears` marker was saved (CP.LiveCtl), the
  in-memory table is rebuilt; the rebuild (`LoadCooldowns`) skips every row created at or before the marker's `all`,
  `type[<type>]` or `mission[<id>]` time, so a clear survives a restart.
- `completionsToday(citizenid, missionType, raw)`: the day count (no type, not `raw`) takes off today's extra runs
  (`cp_officers.cap_extra = { day, n }`, `extraRunsToday(citizenid)`); a type's own count and the hourly count never.
- `admin:changed { citizenid }` drops that officer's cooldown, today and last-hour caches (`_forgetOfficer`).
- `endRun(run, state, endReason)` — state `'completed'|'failed'`; an active participant who is down at that moment (`CP.Qbx.isDowned`, not in the arena) leaves first through `CP.Downed.handle` (result Failed, end_reason `downed`) and only the others get the run's end state
- `noteWeaponFired(run, src)` — server-side proof for `no_weapons_fired` (CP.Npc: a participant's gun hit or gun kill on a mission ped; the `weapon_fired` telemetry also goes through it)
- `objectiveComplete(run, index, data) -> boolean` (false when minSeconds is not reached yet; flags `too_fast`)
- `dispatch(run, index, src, ev) -> ok, reason` — deliver a SERVER-originated event (e.g. from CP.Npc: `{ type = 'cuffed', netId }`, `{ type = 'shot', netId, src }`, `{ type = 'damaged', netId, attacker }`) to the block's `onEvent` of objective `index` (the objective that owns the entity, `cp.obj`), bypassing the client anti-cheat checks
- Test hooks (used by CP.Testing; only valid on test runs): `testSkip(run)` (mark the current objective done regardless of minSeconds and start the next), `testRestart(run)` (block `restart` for the current objective, or stop+delete its entities and `start` again), `anchor(run) -> vec3` (teleport target: the current objective's reference point, or the start before In progress; a second value, the
  net id, when that point is a live entity of the objective: the one it was on while that one lives, else the lowest
  net id, kept in `run.objectives[i].anchorNetId`; never custody's van or its driver, roles `service` /
  `service_driver`)
- Row fields owned by the engine at insert: `season_id = CP.Challenge.currentSeason() and .id`, `department` = the participant's department at the end, `departments_n`, `participants` (active at the end, plus themselves), `tier` = pay tier name, `modifier`, `mission_version`, `location_label`, `duration_s`, `breakdown` = RunResult JSON (9.6)
- `entityDied(run, netId, killerSrc)` — the single death path: marks the entity dead (for corpse cleanup and caps), updates stats, calls the owning block's `onEntityDead`. CP.Npc calls it for peds (with killer attribution); CP.Runs itself detects wrecked vehicles (`GetVehicleEngineHealth <= -3999` / not driveable / `GetEntityHealth <= 0`) and calls it with killerSrc nil
- `failRun(run, reasonKey)` → `endRun(run, 'failed', 'mission_failed')`
- `award(run, id, opts)`, `penalize(run, id, opts)` — `opts = { src = nil (shared) | src (personal), count = 1 }`
- `adjustTimer(run, seconds)` (negative = time off), `pauseTimer(run, paused)`, `remaining(run)`
- `spawnPed(run, opts) -> entity, netId` · `opts = { obj = i, model, coords = vec4, role, armed = false, weapon, accuracy, armour, health, cfg = {}, tag, alt }`
- `spawnVehicle(run, opts) -> entity, netId` · `opts = { obj, model, coords = vec4, role, tag, plate, alt }`
- `spawnObject(run, opts) -> entity, netId` · `opts = { obj, model, coords = vec3|vec4, role, tag, frozen = true, alt }`
- Every new entity of the three asks for its placement (Config.Spawning.place, PLAN S10): the engine's Track calls
  `CP.Spawn.ask(run, netId, entity, kind, opts)` (§5.43, server) once the net id exists and writes what it returns
  into the cp bag as `place` (§6.2) with the first write; `opts.alt` = the other points the block may use there (a
  list of points or `{ coords, label, indoor }`, at most 8 kept: hostile_waves passes the director's spare points),
  where the entity goes instead when an officer's game finds its point bad.
- Spawn director (Config.Spawning, owner request of 2026-10-19: "make sure they dont spawn around the player make it
  be progressive"; blocks call it through `ctx.choosePoints` / `ctx.whenNear`, which fill in `opts.obj`). Every
  distance is 2D, every participant is an active one (`activeSrcs`) at its server-side ped coords.
  - `choosePoints(run, candidates, n, opts) -> points, indexes, spare` — at most `n` (nil = every one that passes) of
    the block's `candidates` (best first: vec3/vec4, `{ x, y, z }`, `{ [1], [2], [3] }` or `{ coords, indoor = true }`),
    returned as the candidates' own values in list order (hidden ones first, below), with their indexes in `candidates`;
    `spare` = the other candidates that pass the distance and behind rules (the ones in the wave's sector first, then
    the rest, in the same order), where an entity whose point an officer's game finds bad may go instead (§5.43).
    Skipped: a point closer than `minDistance` to any participant (`minDistanceIndoor` with `opts.indoor` or a point's
    own `indoor = true`); a point "behind" a participant within `activateRange` of it, i.e. more than `behindAngle`
    degrees between participant → point and the participant's own line to the scene, participant → `opts.centre`
    (default the middle of the candidates), whichever side he came in from: a point between an officer and the scene is
    never behind him, a point at his back always is (a participant within 5 m of the centre has no line of his own and
    faces the way in, `opts.from`, default `location.start.coords`, → the centre; none when those two are under 5 m
    apart); and a point outside the wave's sector: the points left must fit in one `maxSpread`-degree sector seen from
    the participants within `activateRange` of the centre (all of them when none is), the one that holds every point of
    `opts.placed` (what this wave already used), then the most points up to `n`, then the block's earliest point. Too
    few good points: fewer come back, never a bad one. `opts.wave` names the wave: its clock (in `run.spawning[obj]`)
    starts at the first ask (`opts.since`, an `os.time()`, sets it instead) and is dropped once a call returns all `n`;
    after `waveDelayMax` seconds the distance becomes `min(that distance, hardMin)`, never lower. `opts.name` names the
    list for the console; a candidate `{ coords, label = 'yard[3]' }` is named by its own label (hostile_waves names
    each point by its location key and file index, a ring copy `spawns[3] +1.25 m`).
    Console (with `Config.Spawning.log`): one `CP.log` line per skipped point, reason and wave (`run <id>: spawns[7]
    skipped: 30 m from <name>` / `behind <name>` / `outside this wave's 150 degree sector`, the last only when the wave
    is short of points for it) and one `CP.warn` per wave that used closer points after the wait.
    `Config.Spawning.enabled = false`: the first `n` candidates as they are. `testRestart` clears the objective's
    clocks.
    Hidden first (`Config.Spawning.preferHidden`, PLAN S5): when more candidates pass the distance and behind rules
    than `n`, the block did not pass `opts.ordered = true` (keep its own order and ask no game: pursuit's car slots on
    a road, PLAN S13) and the caller can yield (`coroutine.isyieldable()`), the director asks the games of the participants
    within `activateRange` of the centre (nearest first, at most 4; none that close: the nearest one) through the
    ox_lib callback `crimson-police:client:spawn:visible` (§8.1, `CP.Spawn.visible` §5.43) with the first 32 passing
    points and `ms = losTimeoutMs - 250`, each ask in its own thread, and waits at most `losTimeoutMs` (`Wait(50)`).
    A point is hidden only when every asked game answered with a table whose entry for it is exactly `false`. No
    usable answer from one of them (timeout, a raised callback, no table), or one of them still busy with an earlier
    ask (a per-player flag cleared when ox_lib's await returns), means nothing is known: the block's order, one
    `CP.log` per wave (`run <id>: <name>: no usable answer from <officer> within <ms> ms, every point counts as
    seen`). After every wait (answered or not; a busy game or a call that cannot yield does not wait) the rules run
    again from the participants' coords, so an officer who walked up meanwhile never gets a point inside the
    distance. With an answer the passing points are then ordered hidden first (a candidate `{ coords, first = true }`
    stays ahead of all others: hostile_waves marks the boss's own spot), each group in the block's order, and the
    sector choice counts hidden points (a `first` one counts as hidden) after the wave's own points and the number of
    points: of two sectors with as many points, the one with more hidden points wins. One `CP.log` per wave: `run <id>: <name>: <k> of <m> points out of the
    officers' sight, used first`. `preferHidden = false`, `enabled = false`, `#passing <= n` or a caller that cannot
    yield: nobody is asked.
    Out of sight instead of far (`opts.unseen = true`, PLAN S16: a Manhunt clue, a harmless thing that only must not
    pop up in front of an officer): a point that fails only the distance rule (not behind anyone) still passes when no
    asked game can see it. When fewer than `n` points pass otherwise (one point, `ordered` or not), the games are asked
    about those close points the same way (`AskHidden`; the rules run again after the wait) and the hidden ones are
    added after the others; the rest are skipped with one `CP.log` per point (`<name> skipped: 25 m from <officer>
    and not known to be out of his sight`); such a point never counts towards the "closer points after the wait"
    warning. That ask replaces the hidden-first one in the same call. `preferHidden = false` (or a caller that cannot
    yield, or a busy game): nobody is asked and the close points are skipped.
  - `whenNear(run, point, range) -> boolean, nearestMetres|nil` — true when a participant is within `range` (default
    `activateRange`) of `point`; always true while `Config.Spawning.enabled = false` and for a point that is none.
  - Stage ahead (`Config.Spawning.stageAhead`, PLAN S3; §4.4 step 3, §7.1): while objective i is current, the 1 s tick
    calls objective i + 1's block hook `stage(ctx, dt)` (when the block has one) once a tick until i + 1 starts, with
    objective i + 1's own ctx, so what it spawns belongs to i + 1 from the start (`ownerOf`, `entitiesFor { obj }`, the
    caps) and is deleted at the end like every run entity. `stage` returning true sets `run.objectives[i + 1].staged`
    (`ctx.staged` in every later hook of that objective, its `start` included; console `run <id>: objective 2 staged
    ahead (objective 1 running)`, `... (objective 1 done)` when objective 1 completed while it staged); an error sets
    `stageOff` (never called again, `CP.warn` `run <id>: objective 2 stopped staging ahead after an error; it starts as
    before`). `stage` may yield (a spawn waits for its entity): `run.objectives[i + 1].staging` (the tick's thread) is
    set while it runs, and `StartObjective(i + 1)` called meanwhile (objective i completed by an officer's event)
    waits for it with `Wait(0)`, at most `TICK_STUCK_MS` (30 s), never from inside the hook itself or where it cannot
    yield; held longer, the objective starts unstaged and the stage's return is not marked staged (`CP.warn` `run
    <id>: objective 2 started before its stage ahead returned`). A staged entity's events reach its own objective's
    block before it starts (`onEntityDead`, `dispatch` from CP.Npc, `rescale`), never `onParticipantLeft` or `tick`;
    its client half has not started. `testRestart` clears `staged` of the objective it restarts. Off (`stageAhead =
    false` or `enabled = false`, read live): never called; a missing key counts as on (the shipped value).
    Used by `hostile_waves` objectives with `stage = true` (the raids' fights, §3.3; `Config.Spawning.stageWakeRange`
    wakes their calm crew early).
- `deleteEntity(run, netId)`, `entitiesFor(run, filter) -> list`, `canSpawn(run, n, armed) -> boolean` (caps `Config.Limits.maxArmedAlive` / `maxEntities`, counted now; callers wait and retry, never cut counts)
- `send(run, eventName, ...)` → `TriggerClientEvent` to every active participant
- `objectiveEvent(run, index, data)` → `crimson-police:client:objective` (runId, index, data)
- The objective pointer (Config.Markers, PLAN M2; drawn by §5.44): `marker(run) -> marker|nil` — the current objective's
  pointer in the §5.44 shape: its block's `marker(ctx)` hook (§7.1) when the block has one, normalised (keys as strings,
  a net id is its own key, coords `{ x, y, z }` to the centimetre, labels as text or a CP.Lt token string, a target's
  `beyond` above 0 to the decimetre, at most 32 targets, a target with neither coords nor a net id dropped); `false`
  from the hook = none (the block shows the objective itself); no hook, a hook that returns nil or no marker (one
  `CP.warn` per block), or one that raised an error (then not called again for that objective,
  `run.objectives[i].markerOff`) = the fallback, named after the objective (else `markers.objective`), so every
  objective, a Mission Builder one included, has one: a pin `{ kind = 'point', look = 'objective', coords = anchor(run),
  label }`, or, when the anchor is a live entity of the objective, that entity as the one target `{ kind = 'targets',
  label, targets = { { key = netId, netId, x, y, z, look = 'objective', label } } }` (each game follows it, Radio
  Silence 'area' hides it like any person or car). nil while `Config.Markers.enabled = false` or no objective is active.
  `startMarker(run, i)` — the pointer for objective i's `client:objective` `{ action = 'start', marker }`
  (StartObjective, `testRestart`), remembered in `run.markerSent`. `syncMarker(run, nowMs) -> sent` — called right after
  the block's `start` and at the end of every 1 s tick: sends `client:marker` (runId, index, marker) to the participants
  only when the pointer changed since it was sent: a new shape (kind, keys, net ids, looks, labels, numbers, beyond,
  radius, route, a fixed point's place) at once, new positions (targets, or a point that names a net id, to the metre)
  at most every `Config.Markers.trackEvery` seconds (1-10); nil (enabled turned off, a hook now false) is sent once,
  which clears it. `actionPoints(run) -> { { coords, radius? } }` (PLAN M11, for CP.Route's late partners, §5.12): the
  current objective's `anchor(run)`, then the pointer last sent (`run.markerSent.marker`, no block hook runs): its point
  or circle (`radius` for an area), every target at its server position (a target with only a net id: the run's
  entity where the server has it); empty before In progress.
- `hud(run, patch)` → `crimson-police:client:hud` to participants; `hudFor(run, src, patch)`
- `view(run, src) -> ActiveMissionView` (§9.4) and `summary(run) -> LiveRun` (§9.5)
- `isParticipant(run, src)`, `activeSrcs(run) -> list`, `host(run) -> src`
- Handles `server:objective` (runId, index, evidence) → `CP.AntiCheat.checkEvent` → block `onEvent`; the
  server-only types (`cuffed`, `decide`, `action`, `removed`, `handed_over`, `impounded`, `shot`, `damaged`: sent
  by CP.Npc / CP.Custody through `dispatch` / `entityEvent`; `opp_contact`, `opp_cuffed`, `opp_released`,
  `opp_detained`, `opp_booked`, `opp_down`, `opp_up`, `opp_lost`, `opp_left`, `opp_void`, `opp_in_place`,
  `opp_left_spot`, `opp_out_of_bounds`, `opp_cuff_attempt`: sent by CP.Opponents, §5.45) are refused and flag the
  sender `unexpected_event`;
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
- The flee clock (Config.Flee): GTA AI has no stamina, so the 1 s watcher adds the time every ped spends in
  `'fleeing'` on foot to `rec.fleeSpent` (kept across flee/hostile flips, a surrender and a feint; a state change away
  from fleeing counts up to that moment). Time fleeing on foot only: while `GetVehiclePedIsIn(e, false) ~= 0` (a field
  contact's driver who bolts drives off in the `'fleeing'` state) nothing is counted and the gait is `'sprint'`; the
  clock is kept for when he is on foot again. The gait is `'sprint'` until sprintSeconds, `'jog'` until +
  jogSeconds, `'walk'` until + walkSeconds, then `'spent'`, each time × (1 ± jitter: one roll per ped from `CP.U.rng`
  of the run seed and its net id, the same whenever the record is made again) × `CP.Scaling.feel().fleeMult`. No
  active participant within recoverRange for recoverSeconds sets the clock back to 0. With armedTire = false a ped
  whose bag or engine record is armed (never armedTruth) does not tire; with enabled = false nothing tires and no gait
  is written (a gait already written goes back to `'sprint'`). While the ped is fleeing, a gait change is written as
  the bag key `gait` through `setState(run, netId, 'fleeing', { gait = g })` (same state: the task and taskSeq are
  kept, so no re-task); a ped that turns to fleeing again gets its clock's gait in the same write. A missing gait is a
  sprint.
- `gaitOf(netId) -> 'sprint'|'jog'|'walk'|'spent'|nil` — the clock's gait now (`'sprint'` when Config.Flee is off,
  the ped does not tire or it sits in a vehicle; nil for a net id that is not a living ped of a live run)
- `fleeClock(netId) -> { gait, spent, sprint, jog, walk, inVehicle }|nil` — read only: the seconds run on foot so far,
  the seconds of running at which this ped's sprint, jog and walk end, and whether it sits in a vehicle now
- `wornOut(netId, near) -> boolean, task|nil` — the give-up rule of a worn-out runner (Config.Flee.exhausted,
  giveUpRange 5-100 m, read live): true when `gaitOf(netId)` is `'spent'` (so never while Config.Flee is off, for a ped
  that does not tire or one in a vehicle), exhausted is not `'walk'` and `near` (the block's own metres to its nearest
  participant) is within giveUpRange; the second value is the task the block writes with its own surrender: nil for
  `'surrender'` (a missing or unknown value; he kneels, the host's surrendered re-task) or a fresh
  `{ action = 'handsUp', args = {} }` for `'handsUp'`. It reads only the server's clock (never the bag) and not the
  ped's state: the block checks that (§3.3 "Worn-out runners")
- A second `weaponDamageEvent` listener (Config.NpcCombat.cancelLethalHeadshots): `CancelEvent()` for a hit with
  `willKill` whose `parentGlobalId` is an armed, living mission ped of a live run and whose every hit is the ped of
  an active participant of that run in routing bucket 0, not in the arena, and healthy: the server's
  `GetEntityHealth` / `GetEntityMaxHealth` of that ped (the synced health node) give at least
  `CP.NpcCombat.lethalCancelAbove()` (0.75) of the part above GTA's 100-point death line. willKill is any hit the
  shooter's game expects to kill, so the shot that finishes off a hurt officer is never dropped; unknown health
  (0) is not healthy. The only `CancelEvent` of the
  resource (docs/CRIMSON_ARENA.md rule 11). It runs after the listener above and does nothing when the event was
  already cancelled.
Client (host runs AI; all participants see targets):
- `apply(entity, cfg)` — model config from the `cp` bag: accuracy, armour, health, weapon,
  `SetPedDropsWeaponsWhenDead(ped, false)`, 
  combat attributes by behaviour, no ragdoll/flee when hostile (relationship groups `CRIMSONPOLICE_HOSTILE`/`CRIMSONPOLICE_NEUTRAL`)
- `task(entity, action, args)` actions: `combat` (nearest participant), `flee` (from participants, or along points, at
  the bag's gait), `handsUp`, `kneel`, `cuffed`, `follow` (walk to coords), `cower`, `wander`, `enterVehicle`, `driveTo`, `driveRoute` (TaskVehicleDriveToCoordLongrange waypoint by waypoint)
- Reacts to `cp` state bag changes (`AddStateBagChangeHandler('cp', ...)`) on the host: surrendered →
  hands up then kneel; cuffed → cuffed anim + freeze; fleeing → flee; hostile → combat. A task that undoes a pose
  (`Release`, and `kneel`) lets the ped go (`FreezeEntityPosition(ped, false)`) only when `CP.Spawn.holds(ped)` is
  false (§5.43: he still waits for his placement, PLAN S9); else the task runs with him frozen, and the host loop lets
  him go once the ask is gone.
- Server: `setPlace(run, netId, place|nil) -> bool` writes CP.Spawn's placement ask into the entity's bag, or removes
  it (§6.2): through this module's record when it keeps one for the entity (so its later writes keep or drop the ask),
  else into the engine's copy (`run.entities[netId].bag`); no `seq` change, nothing is re-tasked. `place` is one of the
  bag keys `setState`'s `extra` cannot write.
- `nearestParticipant(coords) -> ped, dist` using the run's participant list.
- Config.NpcCombat (§5.42) in `apply`: the weapon through `CP.NpcCombat.weapon` (an older bag's automatic is
  swapped), `CP.NpcCombat.ammo()` rounds, the accuracy at most accuracyMax, and for an armed ped not calm the caps:
  `SetPedShootRate`, `SetPedFiringPattern`, the combat ability at most abilityMax, attributes 27 (perfect accuracy)
  and 24 (proximity fire rate) off, 49 (enemy accuracy scaling) on, and with noCharge 13 and 50 off (also in every
  behaviour). The firing pattern goes on again after each `TaskCombatPed`.
- The combat governor: every participant's game (not only the host) applies those caps (settings only, never a
  task; its only task is the flee of a tired runner below), to each armed mission ped of its run it owns (`NetworkHasControlOfEntity`), once per entity handle and bag
  `seq`, and again when it owns the ped again after another game had it (1 s loop while on a run). On the same
  terms it holds a calm person waiting `idle` with no `contact` in the bag (a raid's staged crew before the breach)
  to the host's calm settings: `SetBlockingOfNonTemporaryEvents(true)` and `SetPedFleeAttributes(0, false)`, so an
  officer aiming at him or a shot nearby never makes him run on the game OneSync gave him to.
- Tired runners (Config.Flee, the bag key `gait` of the server's flee clock; missing = sprint, ignored unless the
  state is `fleeing` and Config.Flee is on): the host gives every flee leg on foot at the gait's move blend ratio
  (TaskFollowNavMeshToCoord: sprint 3.0, jog 2.0, walk and spent 1.0) and gives the current leg again when the gait
  changes (same state: the bag handler does not re-task). A tired runner with no route left (or at its end) runs
  navmesh legs of 40 m straight away from the nearest participant instead of TaskSmartFleePed (no speed argument):
  to the GetSafeCoordForPed point (flags 2 + 8: not isolated, not water) when it lies at least 10 m ahead along that
  line and no nearer to that participant than he is; none that way (a shore, a pier's end, a dead end): the same
  40 m at 60, -60, 90 and -90 degrees off it, in turn; none at all: TaskSmartFleePed (the pacer holds it to his
  gait). ENAV_NO_STOPPING; the next leg 5 m before the end, when stuck, or when a participant is nearer its end than
  he is; stuck on 2 legs in a row (no navmesh path: the task stands him still): TaskSmartFleePed. A sprinting runner
  keeps TaskSmartFleePed, a driver his car. A tired runner with no route (no `fleePoints`) whom the AI loop of the
  game that owns him does not run (a partner's game, or the host's after it lost him for 10 s) and who stands still
  (under 0.3 m/s) for 3 governor passes gets a flee task again from that game: the host's full flee (away legs, its
  AI loop), or TaskSmartFleePed on any other game (it never ends; that game's pacer holds his gait).
- The pacer: every participant's game (host or not) holds each tired runner of its run that it owns (on foot,
  alive) to his gait every frame (`Wait(0)` while there is one): `SetPedMaxMoveBlendRatio` 2.0 (jog) or 1.0 (walk,
  spent) and `SetPedMoveRateOverride` jogRate / walkRate (0.5-1.0), both of which last one frame; with
  windedClipset the movement clip set `move_m@JOG@` (jog) or `move_injured_generic` (walk, spent) once
  `RequestClipSet` has loaded it (3 s at most). A new bag reaches it in the same frame; the 1 s governor loop picks up
  a runner OneSync hands over. It lets go in the same frame (cap 3.0, rate 1.0, `ResetPedMovementClipset`) when he
  is no longer tired: another state, a sprint again, a vehicle, dead, Config.Flee off, another game owns him (that
  game holds him), the run's end, the resource's stop; a game that gets back a ped a bag had marked tired, after his
  breath came back, resets it once.
- Animation sets (K16): the run's end on this player's game (client:runEnded of the current run) and the resource's
  stop let go of every animation dictionary the poses and tells loaded (`RemoveAnimDict`) and of the jog and winded
  walk clip sets (`RemoveClipSet`, loaded or not), so they do not stay resident all session. The next run loads them
  again when it needs them (3 s at most each).

Parity-plus additions (WP2; docs/notes/custody.md):
- States `contacted`, `escorted`, `seated`, `released`, `handed_over`, `impounded`; contacted, escorted and seated are
  protected (shot_surrendered); `isNeutralised` accepts dead, cuffed, escorted, seated and handed_over.
- `adopt(netId, obj)`; a hidden contact is refused 'hostile' until `CP.Runs.arm` gave it its weapon.
- excessive_force: a participant's melee or taser hit on a cuffed, escorted, seated or contacted ped
  (weaponDamageEvent), the health-drop fallback, and validated `stun_hit` telemetry; at most once per person per 10 s.
- `watch(run, netId, src, range)`, `inReachSince(run, netId, src) -> ms|nil`, `unwatch(netId, src)` (the dwell sampler
  of police actions, peds and vehicles); `stunMatches(netId, windowMs)`, `runOf(netId)`.
- `stunProof(netId)`: the server saw that person ragdoll within 1 s (the watcher's sample or `IsPedRagdoll` now). A
  state change is no proof here (a cheat menu could send the report the moment a runner starts to run); the game
  repeats the report every 1.5 s while he is down. Always true with `Config.AntiCheat.stunNeedsProof = 'off'`.
- `stunCheck(run, src, netId) -> ok`: a block's `stunned` report (flee_arrest, pursuit, search_area, field_contact)
  under `Config.AntiCheat.stunNeedsProof` (through `CP.AntiCheat.stunReport`, §5.26): `'flag'` (shipped) takes it as
  before PF1 and, when the server saw no fall, adds one `stun_unproven` staff note per officer and run (nobody's
  points are held); `'hold'` the same with a `stun_unproven` flag on that officer (his row is held for review);
  `'strict'` refuses an unseen stun (the block answers `no_stun` and the person keeps running); `'off'` takes every
  report in range with no check (the distances alone decide).
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
`Config.Route.required` (the owner's switch for Hard rule 17, shipped `true`) is locked at accept as
`run.routeRequired` (sent in `client:start` as `routeRequired`; a test run is always `true`, its Start route switch
decides): with `false` the reports, Recalculate and the arrival check stay, but no warning, countdown, drift check or
`off_route` end; `status` carries `required` and `CP.Runs.view` copies it to `route.required`.
`requiredFor(run) -> boolean` (V9) is the one decision: `run.routeRequired` once locked; before the lock (CP.Runs
calls it in `create`) a test run `true`, a live crime (`run.live`) `Config.LiveCrime.requireRoute == true` (shipped
false: no warning, countdown, drift check, `off_route` end or type cooldown from it; the GPS line, Recalculate and the
start timeout stay), every other run (NPC missions and volunteer suspects) `Config.Route.required`. Late joiners
(V15) begin with the run's locked value.
First contact (V9, `Config.RealSuspects.routeEnds`, shipped `'first_contact'`): in a case with a real suspect
(`run.realSuspect`) the 1 s tick, before the distance-to-start test, counts a participant as arrived (`markArrived`,
the route watch stops) when `CP.Opponents.nearAny(run, coords, contactRange)` is true; `'start'` = only the start.
Late partners (PLAN M11, owner decision; `Config.Route.lateArriveRange`, shipped 150 m, 0 = off): once
`run.state == 'in_progress'`, the 1 s tick switches a participant who has not arrived to mode `'action'` once: no
warning, report, drift or `off_route` check any more (with `required` on or off), reports and Recalculate are refused,
`status` is `{ status = 'action', distance, secondsLeft }` (metres to the action; the seconds until his start
deadline) and he gets `client:routeStatus` (runId, that status) plus a `run` push. He arrives (`markArrived`, as at the
start) inside the start circle or within the range of `CP.Runs.actionPoints(run)` (anywhere inside a pointer circle).
Step R6: on that switch `CP.Runs.extendStart(run, src, Config.Route.followActionSeconds)` (shipped 300; 300 when the
key is missing, 0 = not called) moves his start deadline (`p.deadline`, os.time, the one TickRun removes him at with
`start_timeout`) to now + that, never earlier than it was; only an active participant who has not arrived.
Client: `begin(runId, startCoords)` (waypoint + GPS sampling every `Config.Route.sampleEvery` m with
`GetPosAlongGpsTypeRoute`), `recalculate()`, `stop()`, reports every `Config.Route.reportEvery` s;
client actions `setGps`, `recalcRoute` registered with `CP.Tablet.registerClientAction`. `current() -> { runId,
arrived, routeOn, action }`. `follow(runId, dropStart, secondsLeft) -> boolean` (CP.Runs calls it on
`client:routeStatus` 'action' with that status' secondsLeft): a new token stops the sampling and the reports, a pending
Recalculate resolves, the HUD route is `{ status = 'action', secondsLeft }` (the HUD counts it down and, like the run
bar, shows it from 120 s, `ACTION_LEFT_SHOWN`);
`dropStart` (CP.Markers `leads`) removes the start pin (line off first) and our start waypoint before `action` is set,
so CP.Markers' objective line is his one line; without it the pin loses its line and our waypoint stays (put back when
he has none). `setGps` / `recalcRoute` then answer `err.route_action`; arrival toasts `route.arrived_action`.
The named start pin (PLAN M9; `Config.Markers.startBlip`, look `Config.Markers.kinds.start` through
`CP.Markers.style`) lives from `begin` until arrival / `stop`. Its blip route is on while the route is sampled (the
radar-blip slot is read first) and afterwards only while our waypoint is gone (`IsWaypointActive` /
`GetFirstBlipInfoId(8)` more than 15 m from the start), re-checked with every report and switched only on change;
`setGps` turns it off at once. `startBlip = false`: the pin exists only while the route is sampled.

### 5.13 CP.Calls — modules/calls (Hard rule 15)
- `isOnCall(src) -> boolean` (a live real-call responding entry, `Config.Calls.respondingExpiry`)
- `isOnCall(src, { except = set })`: entries matching an `exemptFor`-shaped set are ignored (a claim of that case, V14)
- `exemptFor(run) -> { exact = { [id] = true }, prefixes = { ... } }` (V9, critic C1 / C15): exact = the case's own
  call (`run.live.dispatchId`, as sent and normalized); prefixes = `'<prefix><src>_'` for every participant and every
  suspect (`CP.Opponents.caseOf(run)`, the watch's server ids) with each `ownRunCallPrefixes` entry plus `shots_`
- Listens through `CP.Dispatch.onResponding` / `onCallCleared`; npccall- ids never end a run;
  own-run call ids (`Config.Calls.ownRunCallPrefixes` + `<partnerSrc>_`) are ignored for partners; on a run with
  `run.realSuspect` every id that matches `exemptFor(run)` is ignored too;
  only `CP.Dispatch.lookupActiveCall` hits count; ends the run with `real_call` and within
  `Config.Calls.dodgeWindow` of an un-mark calls `CP.Runs.reclassify(..., 'real_call_cancelled')`.
- An admin's **Treat as a normal abandon** (CP.LiveCtl, §5.39) uses the same `CP.Runs.reclassify` on a free abandon
  of the last 24 h, found from the saved rows (`end_reason = 'real_call'`), never from this module's memory.

### 5.14 CP.Alerts — modules/alerts (Hard rule 16; the only writer of the crimsonArena bag)
- `set(src, run)` → `Player(src).state:set('crimsonArena', { active = true, source = 'crimson-police' }, true)`;
  refused (false, one log line per run) for a run with `run.realSuspect` while `Config.RealSuspects.officerAlerts` is
  not `'silenced'` (`alertsGoOut(run)`, shipped `'normal'`: the officers' own calls go out); with `'silenced'` only an
  active participant gets it (a suspect never does)
- `releaseRun(run) -> n` (V9): clears every active participant's flag of ours once a run became a case with a real
  suspect (a volunteer who says yes after an officer arrived); nothing while `alertsGoOut(run)` is false
- `clear(src)` → only when the current value's `source == 'crimson-police'`; sets it to nil (replicated)
- `has(src) -> boolean` (our flag is on)
- `foreignFlag(src) -> boolean` — a `crimsonArena` value with `active == true` whose `source` is not `'crimson-police'` (Crimson-Arena's). `set` does nothing (returns false) while a foreign flag is present.
- `inArena(src) -> boolean` — `foreignFlag(src) or GetPlayerRoutingBucket(src) ~= 0` (the gate every module uses)
- `wanted` intent table, re-assert of our flag after a foreign wipe, `foreignClearedAt[src]` — see docs/CRIMSON_ARENA.md rules 1–3 and 9
- `hold(src, on)` (CP.Downed keeps a downed participant's flag), `forget(src) -> boolean` — drops our intent, hold, orphan timer and queued re-assert **without touching the bag** (CP.Runs uses it when an in-arena participant leaves; CRIMSON_ARENA rule 1)
- Start: removes leftover Crimson-Police flags from every online player. Stop: clears all.
- Backstop listeners (shots fired within `Config.Alerts.backstopRadius` of the run's start or the
  participant's objective area; person down/dead while flagged) → clear after `Config.Alerts.backstopDelay` s.
  Skipped for runs where `alertsGoOut(run)` is true.

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
`reasonFor(run) -> 'downed'|'downed_case'|'downed_kept'` (V9): in a case with a real suspect and
`Config.RealSuspects.downed ~= 'failed'` (shipped `'keep_earned'`) a live officer leaves with `downed_case` and a
volunteer-suspect officer with `downed_kept` (§4.3; `CP.Runs.endRun` uses it too); every such case waits
`Config.RealSuspects.downedPickupDelay` (shipped 400 s, sc-ambulance's DeathTime) instead of `Config.Downed.pickupDelay`.
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
Full admin control (P3, §5.39): `adminList() -> AdminUnit[]` (§9.5), `adminGet(unitId) -> unit|nil`,
`adminRemove(unitId, src) -> ok, data|errKey` and `adminDisband(unitId) -> ok, data|errKey`: refused while the unit is
locked for a run (`err.live_unit_locked`), in a ready check (`err.live_unit_ready_check`) or has a member on a run
(`err.live_unit_on_run`); the members get the leader-kick and disband toasts (`unit.admin_removed_you`,
`unit.admin_removed`, `unit.admin_disbanded`). Units stay memory-only.

Parity-plus additions (WP5; docs/notes/teams.md): `kick(src, target)`, `promote(src, target)`, `disband(src)` (leader
only; `err.unit_locked` once a type is accepted; a kicked officer can't be invited by that unit for
`Config.Units.kickReinvite` s), `cancelInvite(src, target)` (leader or inviter), `Config.Units.invitePolicy`
('anyone' | 'leader'), `readyCheck(unit, typeKey, onReady, onCancel, extra?) -> started` (units of 2+: every member
but the leader gets `client:readyCheck` with the type and `extra.twists`, never the mission; the ReadyCheckView has
`twists` too; all accept → onReady once; a decline, the timeout
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

Full admin control (§8.4.2): `history(args) -> Paged` (callback `admin:getOperations`: `cp_operations` plus
participants and points from live and archived run rows, the union in a derived table); an admin may launch during
the cooldown (`server:admin:opLaunch { skipCooldown = true, reason }`, audited `opLaunchSkipCooldown`); `launch`,
`relaunch` and the start refuse `err.maintenance` while `CP.Maintenance.active()`.

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

Full admin control: `paidToday(citizenid) -> number|nil` — cash counted against `Config.Cash.dailyCap` today. A manual
cash payment (`mission_type = 'manual_award'`, `mission_id = 'manual_cash'`) is outside the daily cap: neither cut by
it nor counted in it (the cap lookup of `pay` leaves it out too).

Parity-plus: `row:forfeited (rowId)` fires from `forfeit` and the forfeiture job (one UPDATE per row); `officer:loaded
(src)` fires right after the pending payments of a player who loaded in.

Full admin control (economy, §5.40 calls these inside its AdminKit actions):
- **Step markers**: the claimed payment writes `breakdown.cash.step = 'claimed'` with `payAmount` (after the cap),
  `account`, `source` (`server`|`society`), `societyAccount` and `txn` before any money moves, then `'withdrawn'` after
  the society withdrawal and `'added'` after `AddMoney` (one JSON_SET under `cash_status = 'paying'`).
- **Waiting**: `pay`, `payPending` (and so the login payment) do nothing while `CP.Maintenance.active()`; the rows wait
  and are paid by the sweep after the restart, or at once on `maintenance:changed (nil)`. A `left_behind` store never
  pays. The forfeiture job skips while locked, waits up to 60 s for the shared busy lock and holds it (`forfeiture`).
- **Departments**: the payment's department comes from `CP.Access.department`, and from `Config.Departments` when that
  leaves a turned-off department out, so its pay still comes from its own account.
- `amountOf(row)`, `txnOf(row)`, `department(key)`, `rowBusy(rowId, citizenid)` (pay() works on it or the officer's
  payment lock is held), `paymentsHeld() -> kind|nil`, `nextForfeitureAt() -> ts|nil`.
- Admin tools, each `-> ok, data | false, errKey`; a money tool claims first, then calls `audit(info) -> id|false`
  (false: the claim is undone, `err.audit_failed`), then moves money under the officer's payment lock, then writes the
  final state: `markPaid(rowId, audit)` (paying → paid/capped, no money), `payAgain(rowId, audit)` (claim
  `breakdown.cash.again`; at step `withdrawn` only `AddMoney`, at `claimed` both, at `added` refused; txn `-r2`; online
  only), `payCapRest(rowId, audit)` (claim `breakdown.cash.restPaid`; pays owed − paid with txn `-r`, `cash_paid` grows,
  status stays capped; a refusal takes the marker back), `clawback(rowId, amount, audit)` (claim `cash_reclaimed =
  cash_reclaimed + ? WHERE cash_reclaimed + ? <= cash_paid`; refused when the balance is lower; RemoveMoney; txn
  `-back<n>`; the department is refunded only when `breakdown.cash.source = 'society'`), `toPending(rowId,
  'unfunded'|'forfeited')` / `backFromPending(rowId, from)` (forfeited only with `cash_paid = 0`, never voided or
  flagged), `adminForfeit(rowId, 'voided'|'cancel')` (held/pending → forfeited; `voided` needs no open dispute and fires
  `row:forfeited`, `cancel` keeps the item rewards).
- A manual cash row (`mission_id = 'manual_cash'`) is not cut by the daily cap in `pay`.

### 5.21 CP.Payouts — modules/payouts (S)
- `typePayout(type) -> amount, adminLocked` · `missionPayout(missionId) -> amount|nil`
- `baseFor(mission) -> B` · `sourceFor(mission) -> 'admin'|'type'|'event'`
- `setType(src, type, amount|nil, reason, role) -> ok, errKey` (nil = clear, admin only; supervisor limits)
- `setMission(src, missionId, amount|nil, reason) -> ok, errKey` (admin only)
- `list() -> { types = {...}, missions = {...} }`
- Registers `server:sup:setTypePayout`, `server:admin:setTypePayout`, `server:admin:setMissionPayout`, callbacks `sup:getPayouts`, `admin:getPayouts`.
- Full admin control (economy): `setType(src, type, amount, reason, 'admin', { unlock = true })` sets the amount and
  leaves the type open to supervisors (audit new value `unlocked:<amount>`); `server:admin:setTypePayout` takes `unlock`.
  `previewAdjust(src, { mode = 'pct'|'amount', value, scope = 'types'|'missions'|'both' })` (−90..+500 % in Lua, or ±
  an amount; each value clamped to `Cash.minPayout`–`maxPayout`; the token is bound to every entry and its old value)
  and `adjustAll(ctx)` (each change through `setType` / `setMission`, so one audit line per value, plus
  `payoutsAdjustAll`; `lockTypes` locks every changed type, otherwise each keeps its lock state). `admin:getPayouts`
  rows carry `outOfRange` and the view `outOfRange` (stored payouts outside the current range) and `supervisorRange`.
  `settings:changed` on `MissionTypes.*`, `Cash.*`, `Payouts.*`, `Events.weeklyBoss.payout`, `Difficulty.cashByStars`
  pushes `payouts` and `board`.

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
- `audit(actor, role, category, action, target, old, new, reason, opts)` — `actor` = src or citizenid or 'console';
  writes `cp_audit` and posts to the category webhook (`cp_webhook_audit|flags|builder|operations`, convars).
  `opts = { noWebhook = true (a bulk row; its summary line posts), critical = true, ident = license }`; every row stores
  `actor_ident`, the acting player's license (`CP.Access.licenseOfSrc`), so every character of one player can be found
- `auditSync(actor, role, category, action, target, old, new, reason, opts) -> id | false` — the row written in the
  caller's thread (false when not in a thread or the insert failed: a money or typed-word action then moves nothing);
  its post is `critical` unless opts says otherwise
- `webhook(category, title, description, fields, opts)` (category 'board' also allowed). The queue holds 100 posts:
  when full, the oldest **ordinary** post is dropped (a `critical` one never is) and, once there is room, one audit
  post says how many were dropped (`_webhookDropped()` counts them)
- `webhooks()` rows gain `discord` (the link is `https://discord.com/api/webhooks/<id>/<token>` or
  `discordapp.com`, the whole host anchored); the link itself never leaves the module
- `storageStatus() -> { mode, folder (the setting, never a full path), tables = { { name, rows } }, totalRows, bytes?,
  files?, version, migrations (CP.Migrations.status()), loadError?, busy?, error? }` — the storage command as data
- `storageCopy(src, direction, force) -> ok, messageKey, vars` — the copy of the `storage copy` command (one at a
  time, never during a run, sharing `CP.AdminKit`'s busy lock); its replies also reach src
- `ownRunCheck(src, runUuid) -> ok, errKey` (public); `missionLabel` names `manual_adjust` and `manual_cash` rows;
  `_auditWhere(args)` also filters `target`, `role`, `actorIdent` and `reason` (LIKE with `%` and `_` escaped) and,
  when `action` is not given, `actions` (a list of at most 30 action names, `a.action IN (...)`; the Audit Log's
  **Cash actions** preset), and `admin:getAudit` rows carry `actorIdent`
- `storage mode reset` (console only): `SUB.storage` hands it to `CP.Sysadmin._consoleStorageMode`, the same as the
  `storagemode reset` subcommand; after a failed start (`CP.Migrations.failed()`) it clears the KVP and answers at
  once without the audit row (`sysadmin.console.storagemode_reset_not_started`)
- After a failed start `Admin.command` refuses every subcommand and the in-game open with `admin.cmd.not_started`,
  except the console's `check`, `storagemode` and `storage mode`
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
- `note(run, src|nil, reason, detail, about?)` — a staff note about one participant or the case (src nil); `about`
  (a suspect's citizenid, CP.Opponents) keeps one case note per reason and suspect instead of one per reason
- Two classes (critic 2 #12): only an **officer's own conduct** is a flag. A flag sets `p.flagged` / `run.flagged`;
  `CP.Cash.compute` then makes the row `held` and CP.Rewards holds its items until a supervisor approves. Everything
  a suspect does himself, and a fact staff should check without holding anyone's points (`stun_unproven` with
  `stunNeedsProof = 'flag'`), is a **note**: the same input checks and clips, cp_audit category `flags` action
  `runNoted` with the arguments `runFlagged` uses (target = run id, old_value = citizenid or nil, new_value =
  reason, reason = detail), its own once-per-(reason, citizenid or `*`, `about`) list per run, a test run only logs
  it, and it never sets `p.flagged` or `run.flagged`. The Review run detail (`sup:getReviewQueue` /
  `admin:getFlagged` rows, `notes = { { reason, detail, note = true } }`) shows the notes of a held run as
  "Note: <flag line>"; the queue still lists only held rows.
- `stunMode() -> 'flag'|'hold'|'strict'|'off'` — Config.AntiCheat.stunNeedsProof read now (a true from before it was
  a choice reads as `'strict'`, false as `'off'`, missing or unknown as `'flag'`); `stunReport(run, src, seen,
  netId) -> ok` — a block's `stunned` report: seen or `'off'` = true; unseen: `'flag'` = true plus
  `note(... 'stun_unproven')`, `'hold'` = true plus `flag(... 'stun_unproven')`, `'strict'` = false (the detail
  names the objective and the person's net id, `admin.anticheat.stun_detail`)
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
silent unless this player controls a test or has an invitation waiting), debug overlay drawing. The panel and the
invitation prompt let go of the NUI focus within 250 ms of the player going down (`CP.Tablet.playerDown`) and take
none while down (toast `test.downed`). `releaseFocus()` (CP.Diag's unstick) and `focusKind() -> 'controls' |
'invites' | nil` (CP.Diag's state).

Full admin control (§8.4.2): `markLocationChecked` (an `unplayed = 1` row, status `checked`, never a draft's pass) and
`hideTestResult` (`hidden`, K on the old value); `list()` ignores hidden rows and gives each mission its `switch`
(`CP.Settings.missionView`). `start` refuses `err.maintenance` while `CP.Maintenance.active()`.

Check spawn points (PLAN S7, Config.Testing.spawnCheck; owner request of 2026-10-19: "Double check all coordinates etc
for every ped"). The server lists the points, the admin's own game judges them with `CP.Spawn.probe` (§5.43); nothing
is spawned and only his ped moves. Refused with `err.spawn_check_disabled` while Config.Testing.enabled or
spawnCheck.enabled is false.
- `spawnPoints(src, { missionId?, location?, point? })` (ox_lib callback `server:test:spawnPoints`, testRun): no mission =
  `{ missions = { { id, label, source, locations = { { index, label } } } } }` of `CP.Missions.all()` in the Testing
  order; a mission = that one (`resolveMission`: archived ones too); a mission and a location (`err.in_arena`,
  `err.spawn_check_on_run`: his game is about to move him) = `{ missionId, missionLabel, location, locationLabel,
  start = { x, y, z, r }, points }`. A point: `{ id ('spawns[7]', 'routes#2[3]'), key, i, kind, as, wall, model?,
  obj, block, x, y, z, h?, above = { lo, hi }, dStart?, dPrevious?, near? }`. `kind` (what is there) is `ped`,
  `vehicle`, `prop`, `marker` or `path`, from the blocks' `pointKinds` (§7.1; a block without it: its
  `requiredPoints` as markers; a key no objective uses: a marker with `obj = false`); a key two objectives use takes
  the higher of ped > vehicle > prop > path > marker, and its first objective of that kind. `as` is what the probe
  judges it as (a marker and a path point as a person: someone stands or walks there), `wall` is true for a person
  and a vehicle, `model` a vehicle's model when the block names one, `h` the file's heading (a vehicle at a route's
  first point faces the next one), `above` Config.Spawning.ground of `as`. People, vehicles and objects get the 2D
  distance to the start (`dStart`) and to the nearest point of another key the objective before uses
  (`dPrevious`: where the officers stand when it starts); `near = { 'start', 'previous' }` lists those under
  Config.Spawning.minDistance. Built from `GeometryOf(mission, location, nil, { flat = true })`, the debug overlay's
  geometry without a run (every point once, headings kept, at most 1000 points and 64 routes of 1000).
  With `point` (an id, at most 64 characters; PLAN S8 "Teleport here"): `{ missionId, location, point }` (that one
  row), refused `err.spawn_check_teleport_disabled` while Config.Testing.spawnCheck.teleport is false and
  `err.invalid_payload` for an id the location does not have; audited (`audit`/`testControl`, target
  `<missionId>#<index>`, new value `teleport <id>`) and `CP.log`ged.
- `spawnCheckReport(src, { missionId, location, results = { { id, status, groundZ?, dz?, roofZ?, seen? } } })`
  (action `server:test:spawnCheckReport`, testRun): `err.invalid_payload` for an id the location does not have,
  one id twice, more results than points or a status the probe never gives (`ok`, `snap`, `underground`,
  `floating`, `no_ground`, `in_water`, `in_wall`, `interior_not_loaded`, and `skipped`); the server's own coordinates
  are used; a height that is no finite number (or over 100 km) is kept as none. Every status but ok and skipped gives
  one `CP.warn` with tag `spawncheck` (so Admin UI → System → Problems lists it too): `spawn check: gang_shootout #4
  spawns[7] (1153.75, -3169.50, 5.88) UNDERGROUND ground 6.40 (-0.52) [ped; 12.3 m from the start; seen from the
  start]` (`snap` reads HEIGHT OFF: a placer can put it on the ground, the file is still off); one `CP.log` per
  location. The report replaces the location's last one in memory: `spawnReports()` -> copies `{ missionId,
  missionLabel, location, locationLabel, at, by, checked, bad, points }` by mission then location.
- Client: client actions `spawnCheck` (`{ missionId?, location? }` -> `{ started, missions, locations }`; refused
  `err.invalid_payload`, `err.spawn_check_disabled`, `err.spawn_check_running`, `err.in_arena`,
  `err.spawn_check_on_run` (`CP.Runs.current()`), `err.spawn_check_in_vehicle`, `err.spawn_check_dead`,
  `err.invalid_location`, `err.test_unknown_mission`) and `spawnCheckStop` (-> `{ stopping }`: the check ends after
  the point being probed). In a thread: fade out; his coords, heading, freeze, visibility and `GetPlayerInvincible`
  are kept; `FreezeEntityPosition` true, `SetEntityVisible(ped, false, false)`, `SetEntityInvincible` true. Per
  location the points are asked for again (a refusal `err.in_arena`, `err.spawn_check_on_run`, `err.no_permission` or
  `err.spawn_check_disabled` ends the check, another one skips the location): fade, `SetEntityCoords` to 1 m over
  the start (a ped's root is about 1 m over his feet, so he stands on it and the sight check looks from a standing
  officer's eyes),
  `NewLoadSceneStartSphere(start, 200.0, 0)` until `IsNewLoadSceneLoaded` or sceneTimeoutMs (1000-30000), then
  `NewLoadSceneStop`, fade in; `CP.Spawn.visible` from there of the people, vehicles and objects within 200 m (32 a
  time, Config.Spawning.losTimeoutMs) gives `seen`; then each point: a path point is `skipped` unless
  spawnCheck.routes is true; one further than spawnCheck.moveWithin (2D) from where he is: he is moved to 1 m over it
  and the scene loads there; `CP.Spawn.probe(as, x, y, z, h, model, { wall })`. The location's results go to
  `server:test:spawnCheckReport` (only `id`, `status`, `groundZ`, `dz`, `roofZ`, `interior`, `seen`). NUI push topic
  `spawnCheck`: `{ state = 'started', missions, locations }`, `{ state = 'location', progress, missionId,
  missionLabel, location, locationLabel, points }` (or `{ ..., error }` for a skipped location), `{ state = 'point',
  progress, missionId, location, result }` (the server's point with the answer), and at the end `done`, `stopped` or
  `failed` `{ progress, totals = { points, bad, locations }, error? }`; `progress = { mission, missions, location,
  locations, point, points }` (location = its place in this mission's list). Every move re-checks Crimson-Arena (rule
  13): once the arena owns him (or the crimsonArena bag turns foreign: the check stops) he is never moved again and
  his freeze is the arena's; visibility and invincibility come back. A run of his that starts during the check (a
  test he starts or joins: `CP.Runs.current()` before the start move and before each point, or the server's
  `err.spawn_check_on_run`) ends it with `err.spawn_check_on_run` after reporting what was checked, and he is never
  moved again: unfrozen unless he was frozen before, seen and hurt as before, the screen faded in, where he is.
  A logout (`CP.Qbx.onUnload`) ends it like the arena: his ped is never moved again and not let go (qbx's character
  screen freezes and places it), seen and hurt as before, the screen faded in; a scene load stops early then.
  Otherwise, and on resource stop, he is put back where he was, facing the same way, unfrozen unless he was frozen
  before, seen and hurt as before, the screen faded in. A stop in the first fade (before he is hidden) only fades the
  screen in, and a stop ends our own load scene (`NewLoadSceneStop`, never another resource's). A test teleport
  caught by a stop in its fade or ground wait fades the screen in and undoes its own freeze (not of a ped
  Crimson-Arena owns). The test panel's teleport (`testControl` / `teleport` to the
  start or objective) is refused `err.spawn_check_running` while a check runs, and the Testing screen's Start test
  buttons are disabled then.
  A skipped location's push also carries `missionLabel`. "Teleport here" (PLAN S8): the client action `teleport`
  with `{ target = 'point', missionId, location, point }` needs no test run; refused `err.invalid_payload`,
  `err.spawn_check_running` (a check runs: it puts him back afterwards), `err.in_arena`, `err.spawn_check_on_run`;
  then `server:test:spawnPoints { missionId, location, point }` gives the coordinates (the NUI sends none; an answer
  without them is `err.test_control_failed`), the arena and a running check are checked again, and the test
  teleport's move puts him (or the vehicle he drives) on the ground there.
- Admin UI → Testing (PLAN S8): `admin:getTests` `config.spawnCheck = { enabled, teleport, routes }` (enabled is false
  while Config.Testing.enabled is). While enabled the screen shows a "Check spawn points" button and a per-location
  item that open the dialog (`web/src/admin/components/SpawnCheckDialog.tsx`: scope, Start / Stop, progress, the
  results with "Teleport here" and "Copy report"). `web/src/admin/components/spawnCheckStore.ts` takes the
  `spawnCheck` pushes at module level, so a check and its results outlive the dialog and the open tablet; the copied
  report has one line per point to look at in the server's console format.

### 5.28 CP.Builder — modules/builder
Server: drafts, locks, autosave, test runs of drafts (via `CP.Testing`/`CP.Runs` with `test.draft = true`),
publish (Lua export with `SaveResourceFile`), archive/restore, rollback (.bak), reload of hand edits,
`loadPublished() -> { def, ... }` *(hook for CP.Missions.loadAll)*, `onReload()`,
`onDraftTested(missionId, version, tierName, passed, src, defHash)` *(hook from CP.Testing; a pass counts only for the draft content with that defHash)*. Testing is optional: a passed test at the tier `CP.Scaling.tierFor(maxOfficers)` (`draft_tested = 1`) is needed to publish only while `Config.Builder.requireTestToPublish` is true, and only for supervisors (never admins). List entries carry `needsTest`, `builder:config` carries `requireTestToPublish` (for the viewer), and an untested publish is audited as `publishUntested`.
Client: placement tool, route recording, test drive; overlays through `CP.Tablet.overlay`.

Full admin control (§8.4.2): edited built-in missions are override rows (`cp_custom_missions.overrides_builtin = 1`,
`base_hash` = the shipped file's hash when the edit was made or kept) with their files in
`<exportPath>overrides/<id>.lua` (`.v<n>.lua.bak`, `.draft.lua.bak`, `<id>.base.lua` = the shipped file at that
time, `archived/`); never in `missions/builtin/`. Override rows are admin-only in `Allows`, `VisibleTo` and `LoadRow`
(supervisors never, whatever `builderEditAny` says) and only while `Config.AdminControl.editBuiltins` is on;
`changeOwner` and `deleteMission` refuse them. `B.validate(def, { baseline = { def, raw } })` checks an override with
the custom-mission rules, the shipped file as a baseline by value (a model, weapon or zone it uses is allowed, a
number may stay at or below its shipped value). `B.loadOverrides() -> { [id] = { raw, filePath, hash, version,
baseHash, editedInCode } }` *(hook for CP.Missions.loadAll; empty while editBuiltins is off; a missing file is written
again from the row)*, `B.shippedOf(id) -> { path, content, raw, hash }`, `B.editBuiltinsOn()`, `B.onTestHidden(missionId,
defHash)` (a removed pass makes that draft untested again). `Begin()` lets admins past `Builder.enabled = false`.
Armed spawns (PLAN S18): `B.armedKeepOut(start, searchCircle) -> metres | nil` (2D: `start.radius +
Config.Builder.spawnMargin`, never under `minSpawnFromStart`; nil at a search circle) is the distance `B.validate`
holds every armed spawn key to (`ARMED_FIELDS`: hostile_waves spawns / boss.spawn / spawnSets.keys, escort
ambushPoints, pursuit spawn / spawns, flee_arrest associates.spawns; error `builder.error.spawn_armed`; a point a
built-in mission plays at the same start is trusted: the loaded built-ins, and the shipped file of each one not
loaded, listed by `CP.Missions.builtinIds()`; at server start the file sync runs before any built-in is loaded, so a
hand edit is checked against the shipped files). `B.armedTooClose(runtimeDef, builtins?) -> { { location, key,
min, have } }` lists the keys still inside it: `CP.Missions.normalize` warns with it for a published custom file (it
still loads; `meta.builtins` = the built-in definitions to trust, which `loadAll` sets to the ones it is loading).
The client's `B.checkSpot` refuses such a point while placing (`builderPlace` payload `armed`, `startRadius`;
`B.armedKeepOut(ctx)` on the client).
Deleted custom missions go flat into `<exportPath>deleted/` as `<id>-<time>__<file>` and `<id>-<time>__row.json`, with
an `index.json` list whose `folder` is that name prefix (no folder is made per deletion). The export folder and its
`archived/`, `overrides/`, `overrides/archived/` and `deleted/` ship with a `.gitkeep`; `B.ensureExportDirs()` reports
a missing one, and `B.missingExportDirs(path) -> { rel, ... }` is the Settings check of `Builder.exportPath` (a path
whose folders are not there yet is refused with `err.setting_export_folder`).

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
  text|nil` (a saves folder that is missing, cannot be written or cannot be read: every statement then fails with that
  text and nothing in the folder is changed; for a folder outside the resource it names FXServer's sandbox),
  `hasSavedData() -> bool` (the configured folder holds saves), `realMySQL` (oxmysql's `MySQL`, files mode), `db`
  (the engine, files mode), `MemSQL` (the engine's code). A new saves folder is announced on start, once oxmysql is
  connected (`realMySQL.ready`): when the real database holds Crimson-Police data (`cp_schema_migrations` has rows, or
  the database cannot tell) the warning names the storage copy command; when it has none (a first install with the
  database off) one plain line says the folder is empty. A new database next to a saves folder with data is
  announced by the migrations runner, naming the storage copy command.
- **The migrations runner** (`modules/migrations`, `CP.Migrations.ready() / isReady() / version() / started() /
  failed()`): a failed statement (or any error in the runner, which runs under pcall) fails the
  start with the file, the statement and the driver's error, then one `How to fix it:` line for the usual first-start
  errors (no CREATE/ALTER right, a wrong password, no rights on the database, an unknown database, a server or host
  that cannot be reached), for a storage switched to in game the `storagemode reset` line (with
  `Config.Tablet.adminCommand`), and one line naming `ensure <resource>`. A failed start is a state, not a stop:
  FXServer refuses StopResource on the calling resource (citizen-server-impl ServerResources.cpp STOP_RESOURCE), so
  the resource stays started. `failed()` then names what failed (nil otherwise); `ready()` is a barrier that raises
  `err.not_started` at once, and in every thread that was waiting in it; `started()` waits the same way and answers
  true or false without raising (start-up threads and loops end quietly with it); CP.Net answers every action and
  callback `err.not_started` before its handler runs; CP.warn and CP.err drop the lines that carry `err.not_started`;
  the console command registers at once (Settings.waitLoaded returns early) and refuses everything but the console's
  `check` and `storagemode reset` / `storage mode reset` (`admin.cmd.not_started`); the reset answers at once without an
  audit row (`sysadmin.console.storagemode_reset_not_started`). Nothing reads or writes the store after the failure.
  After `CP.Settings.boot()` and before any caller of `ready()` goes on, the runner calls `CP.Sysadmin.startLocks()`
  (the left-behind and unfinished-restore locks), so the cash forfeiture, the pending pay, the reward jobs, the
  clean-up and the admin job resume already see them; each of those also reads the lock after its wait for the store. When oxmysql has not connected 30 s after start (it waits without a word) one warning names
  `set mysql_connection_string` and `Config.Database.enabled = false` (database mode only: the saves folder never
  waits for oxmysql).
- **The database server** (database mode only, `CP.Storage.mode() == 'database'`; the saves folder engine has no
  server version or character sets): before the first table statement the runner sends one probe, `SELECT VERSION(),
  JSON_VALUE('{"a":"b"}', '$.a'), JSON_VALUE('{"a":null}', '$.a') IS NULL`. A server without JSON_VALUE (MySQL before
  8.0.21) or one that reads a JSON null as the text `null` (MariaDB 10.2) fails the start (`failed()` = 'the database
  server is too old', the server named, the fix: MariaDB 10.9 or newer, Qbox's minimum, or the saves folder): every
  payment step uses JSON_VALUE, so it would fail half way. MySQL that has it starts with one warning (Qbox does not
  support MySQL; on MySQL, once an officer has a cooldown clear, cap raise or extra boss attempt, the next is
  refused, as LiveCtl's marker compare-and-set never matches a JSON column, and a copy to the saves folder can reuse
  a deleted run id, as MySQL caches information_schema's AUTO_INCREMENT). A server that does not answer is left to
  the migrations' own errors. After the migrations, every cp_ table whose collation is not utf8mb4 (txAdmin's recipe
  deployer makes the database `CHARACTER SET utf8`, so every table took utf8mb3 and refused emoji) gets `ALTER TABLE
  ... CONVERT TO CHARACTER SET utf8mb4`, one console line each, and its JSON columns (LONGTEXT on MariaDB; no other
  cp_ column is) go back to `utf8mb4_bin` as a utf8mb4 database makes them. A table that cannot be switched is a
  warning and the start goes on. Only cp_ tables are touched. `storage copy files-to-database` runs the same switch
  (`CP.Migrations._utf8mb4Tables(target.rows)`, oxmysql's query, as in files mode `MySQL` is the saves folder
  engine) after it makes the target's tables and before it writes a row, so a saves folder with emoji copies into
  txAdmin's database.
- **CP.Storage.MemSQL** (server; it also runs under plain lua5.4 in the tests, with the global `json`):
  `new({ store }) -> db`; `db:exec(sql, params) -> { kind = 'rows', cols, types, rows, n } | { kind = 'write',
  affected, changed, insertId, info, warnings }`, synchronous and atomic (a failing statement changes nothing),
  and saved before it returns (every changed document written as `.tmp` first, then renamed into place in a
  crash-safe order; a save that fails part way is undone in memory and in the folder); with `db.slice` (set by
  CP.Storage on a server: `{ wait = Citizen.Wait, ms = 4, saveMs = CP.Storage.saveTurnMs }`) a SELECT run from a
  thread gives the server its turn every 4 ms (the clock is read every 32 rows), and every other statement waits for
  it; the answers of JSON_EXTRACT, JSON_VALUE and JSON_CONTAINS are kept per (path, text) in `CP.Storage.MemSQL.jmemo`
  (two generations of half of `jmemo.cap` each, `Config.Database.jsonCacheEntries`, 100000; a hit in the older one
  moves back; the texts an UPDATE replaced are forgotten after the statement, a DELETE keeps them); a DELETE of
  more than 64 rows from one table (`BULK_DELETE_ROWS`: the nightly run archive) leaves them in the table's index
  buckets until its loop ends and then drops them in one pass over each bucket they were in, also when the loop fails
  (the undo then adds every row back), instead of one `table.remove` per row and index, which shifts the whole bucket;
  an UPDATE puts the new row in the old one's place in each bucket whose key it keeps; `db:load()`; `db:bulk(fn)` (the write-through paused, every document saved once at
  the end: bulk imports and the storage copy); `db:tableNames()`; `folderStore(dir, { docRows, label })` (the saves folder: its file
  layout and crash-safe save sequence are in the header of memsql.lua; `label` is the folder as the owner named it, for
  example `saves/second`, in the messages about its files, default dir); `luaRows(res)` (engine rows typed like
  oxmysql).
- **The shim**, `CP.Storage.MemSQL.shim(db, { realMySQL, resource }) -> MySQL`: `query`, `single`, `scalar`, `insert` and
  `update` (each callable with a callback, and with `.await`), plus `ready`. It copies oxmysql's return shapes,
  typing (TINYINT(1) as booleans, DECIMAL and SUM as strings, DATETIME/DATE as milliseconds, text always as
  strings, UPDATE counting matched rows), error text and parameter checks. Any other key (`prepare`,
  `transaction`, ...) raises. With `db.slice.saveMs` (`Config.Database.saveTurnMs`, 4; read at every save, 0 = never)
  a thread that has spent that many milliseconds saving gives the server its turn (`wait(0)`) after the statement
  that used them up, as oxmysql's await yields after every query: never inside a statement (each change is on disk
  before its statement returns), never while a sliced SELECT holds the engine, and not in a thread that cannot yield
  (the main chunk, the migrations at load). The time is counted per thread (a weak-keyed table) and starts again when
  the thread was away longer than the budget since its last save. A callback (`MySQL.update(sql, p, cb)`) whose save
  used up the budget gets its answer a tick later, as with oxmysql. It routes by the tables a statement names: only `cp_` tables go to the engine; only
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
  and missing documents, the SELECT slicing, the one-pass index sweep of a bulk DELETE), `tests/storage_spec.lua` (files mode end to end, a restart, and
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
  handle, reply, side)`, `releaseService`, `serviceStatus`, `_servicesOf(run)` (tests).
- Service vehicles: the driving client is the nearest active participant outside the arena (else the host); it is
  asked for a road point 150–250 m away (`client:roadPoint`), the server checks it (within spawnDistance,
  Config.Custody.serviceClearance, 30 m, from every player, again when it spawns there) and retries every 3 s; the AI
  moves on leave, down, arena or beyond serviceHandoff. A vehicle has arrived when below 1.5 m/s within 15 m of a
  placed parking point (a transport, coroner or tow point), or, for the prisoner van with no transport point,
  anywhere within Config.Custody.transport.parkWithin of the scene; after serviceTimeout a van is placed at its
  parking point and a tow that did not load fades the car (impounded). PLAN S17: a van is placed only while no player
  is within serviceClearance of its parking point. A late van (`Placed`) drives on until then and is moved with
  SetEntityCoords plus `CP.Spawn.again` (it waits frozen for an officer's game, from = where it was). A van that got
  no road point (`Fallback`) asks the driving client for one beside the scene (`side`: `{ near = the parking point,
  min = serviceClearance, max = serviceClearance + 40 }`, the same callback and check) and is made there, or waits. A
  tow truck that got no road point is never made: the car fades out (impounded). Config.Spawning.enabled = false:
  the vans are placed as before.
- People debrief: `register` notes each person (label, demeanour) through CP.Runs.notePerson, and the behaviours
  (walked_away, ran, drew), cuffs, escapes and deaths as they happen; `grade` adds the factLog (every fact the
  decider had, as text, with when it reached them).
- `onCuffed`, `markGone`, `markDead`, `closeObjective(run, obj) -> n` (undecided contacts: missed_offence −5, never a
  fail), `noteForce(run, netId, src)`, `view(run, obj, src) -> ContactView|nil` (web/src/types/custody.ts; choices'
  failsCase only from facts that reached this viewer), `giveEvidence(run)` (Config.Custody.evidenceItem, off).
- Net: plain `server:custody` (runId, netId, action, phase, extra; 4 per 2 s), action `server:contactDecide`
  (`{ runId, netId, choice, offence?, confirmed? }` → `{ ok }` or `{ confirm = { factKey } }`; within 25 m), plain
  `server:stunHit` (netId; 2 per s), `client:contactAct`, `client:contactConfirm`, `client:serviceVehicle`,
  `client:serviceBlip` (PLAN M7, §5.44 `service`), the
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

Full admin control (§8.4.2): `create(src, type, area, { skipWait, reason })` (an admin's **Post anyway** during the
wait between staff calls; audited `mcCreateSkipWait`; the wait still applies to supervisors), `history(args) -> Paged`
(callback `admin:getMissionCalls`), and `claim` refuses `err.maintenance` while `CP.Maintenance.active()`.

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
- Full admin control (economy): `Usable()` checks `forbidden()` itself (an item added in game before the next check is
  never given); `checkSetting(path, value) -> errKey|nil` is registered as the Settings validator of `Rewards` (pool
  shape, chance 0–1, rolls 0–10, count 1–100 or `{ lo, hi }`, weight > 0, value ≥ 0, never a forbidden item), and every
  `settings:changed` on a `Rewards.*` path runs `validate()`. Delivery (`deliver`, a grant's delivery) and the
  forfeiture job wait while `CP.Maintenance.active()`; the forfeiture job waits for and holds the busy lock
  (`rewardForfeiture`). `adminView(args)` takes `{ page, citizenid, status, source, from, to }` (rows gain `rowId`,
  `online`; the view `allowTakeBack`). `checkInventory(id)` (ox_inventory `Search` for the item tagged `cpReward = id`,
  then only the slots whose own `metadata.cpReward` is the id: Search matches metadata values and ignores the keys, so
  an untagged food item's `degrade = 60` would match reward 60; online only), `resolve(id, 'given'|'locker', audit)`
  (`giving` → given, or → pending and delivered again; `err.reward_found` when the item is there), `cancel(id)`
  (pending/held → forfeited), `takeBack(id, audit)` (given → forfeited under the reward lock, `RemoveItem(src, item,
  n, slot.metadata, slot.slot)` of exactly the tagged slots with each slot's own metadata, because RemoveItem matches
  the whole table and ox_inventory added `durability`, `degrade` or `container` and `size` when it gave the item;
  refused and undone when they are not all there), `undoForfeit(rowId)` (on `row:forfeitUndone`: the row's forfeited rewards back to pending, held while the row
  is voided, once; ones an admin cancelled or took back stay), `expected(entry)` (items and value per run at each tier,
  in Lua), `itemChoices()`. Net in §8.4.4.

Full admin control, System (P5): the storage switched to in Admin UI → System is kept in the server's KVP
(`cp_storage_mode` = `database`|`files`, `cp_storage_folder`), outside the storage itself where the settings live, and
read by `Install` before `Config.Database` (which it then reflects); a start-up line names the override and System →
Storage and Config health (`storage`) show it. `effective(cfg, kvp) -> { enabled, folder }, override|nil` (pure, for the
specs), `override() -> { mode, folder }|nil`, `validFolder(f)` (relative, under `saves`, no `..`, no `//`, no full path).
`CrimsonPoliceAdmin storage mode reset` (or `storagemode reset`; console only) clears the KVP. Each store holds `cp_storage_meta` (`generation`,
`state` = `active`|`left_behind`): a switch writes a new generation into both and marks the old one `left_behind`; a
store that starts `left_behind` begins the `left_behind` maintenance lock (CP.Sysadmin, §5.41).

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
A line may also carry `fix` (the Settings path that fixes it: Permissions and Settings show **Open setting**) and
`cfgLine` (a server.cfg line to paste: **Copy the line**); `run()` passes both through. CP.Sysadmin registers `storage`
(an in-game storage choice, a store left behind).

### 5.35 CP.Diag — modules/diag (client; the freeze fix)
F8 command `CrimsonPoliceState`: four `[crimson-police:diag]` lines with the screen fade, NUI focus (and keep input),
scripted camera, pause menu, player control, frozen, dead, last stand and dead metadata, in a vehicle, then what
Crimson-Police holds (tablet, panel focus, test panel focus, pick-up, run) and which of the rest is not ours (the
test panel's and the test prompt's focus are ours: `state().testFocus` is `'controls'` or `'invites'`).
`CrimsonPoliceState unstick` first closes our tablet, releases our panel focus and the test panel's
(`CP.Testing.releaseFocus()`), runs `CP.Downed.restore`, then calls `SetNuiFocus(false, false)` whatever is open: FiveM
keeps one focus vote per resource, so that frees a focus a broken page of ours holds and never touches another
resource's. `state() -> table`, `unstick()`.
Admin UI → Officers → Support (P5): `client:diagUnstick` runs `unstick()`; `client:diagState (token)` answers
`server:diagState (token, state())` (the server keeps only the answer of the player it asked, known keys only).

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
  applied settings are set on it. Restart settings (`Tablet.command|adminCommand|keybind|dispatchKey|readyKey|contactKey`,
  `Testing.panelKey`, `Locale`, `Time.resetHour`, `Leaderboard.weekStartsOn`) apply only at boot; a later change is saved and
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

Full admin control additions (P0; the Settings screen follow-ups are P5's):
- Locked also: `Tablet.title`, `Tablet.command`, `Tablet.adminCommand` (`settings.locked.names`),
  `Calls.npcCallPrefix`, `Calls.ownRunCallPrefixes` (`settings.locked.call_ids`), `Bonuses.*.each|block|engineOnly`
  (`settings.locked.code_fact`). A saved row of a locked path is ignored at boot and can still be reset.
- RANGES for Hard rules 15-18: `Calls.dodgeWindow` 10-300, `respondingExpiry` 60-7200, `Alerts.backstopRadius`
  50-1000, `backstopDelay` 0-10, `Downed.pickupDelay` 5-120, `checkEvery` 1-10, `Route.abandonAfter` 10-120,
  `maxDeviation` 30-500, `reportTimeout` 5-60, `maxDrift` 200-5000, `lateArriveRange` 0-500 (PLAN M11),
  `followActionSeconds` 0-1800 (R6); and for
  the new `AdminControl.*`, `Cash.addFundsMax`, `manualDailyLimit`, `lowBalanceWarn`, `Backups.keep`. Their one
  switch is `Route.required` (Hard rule 17, a plain boolean: not locked, not a money switch).
- `check(path, value, none, ctx)`: `ctx = { pending = { [path] = value } (the other values of the same save), boot }`.
  A template's check is `check(clean, path, ctx) -> errKey | nil, fixed`.
- `Bonuses.*.kind` only with its value (`err.setting_kind_alone`): `setMany(src, changes, opts)` checks every value of
  one save first (each sees the others; a `none` change is `false` in `ctx.pending`), then writes them all;
  `checkMany(changes, opts) -> true, checked | false, errKey` is those checks alone, for a caller that must act only
  when the save will be accepted (the logo upload checks before it writes its file); `Bonuses.*.value` is points -500..500 (whole) or pct
  -1..1 by the kind, sign kept. `reset` of either resets both.
- Point values (`POINTS`: `MissionTypes.*.points`, `Bonuses.*.value|kind`, `Scoring.*`, `Scoring.common.*`,
  `Events.todMultiplier`, `Events.twists.*.points`, `Events.twistMaxPoints`, `Events.weeklyBoss.points`, `CrossDepartmentPoints`, `Difficulty.pointsByStars`,
  `Scaling`, `Goals.dailyPoints|weeklyPoints`, `Challenge.bountyBonus`, `MissionCalls.rapidResponse.pctOfP`): the view
  has `points = true`; a set or reset also posts `settings.points_notice` to the flags webhook.
- Money switches (`MONEY_SWITCHES`: `Cash.allowUnfundedRetry|allowCapTopUp|allowPayAgain|restoreForfeited|allowAddFunds|
  allowClawback|allowManualCash`, `Rewards.allowTakeBack`): the view has `money = true`; turning one on needs
  `opts.confirm` (`payload.confirm`) = `ENABLE` (any case) or `err.confirm_enable`; audited as `moneySwitch` (old/new
  `off`/`on`), critical.
- Row templates (kind `rows`, view `rows = { fields = { { key, kind = text|number|enum|vector, min, max, integer, options,
  size, position, optional } } | bare, min, max }`): `Builder.noBuildZones` (the Crimson-Arena rows may grow but never
  move, shrink or go: `err.setting_arena_zone`), `Downed.dropOffs` (1-10 points), `MissionCalls.areas` (unique keys),
  `Scaling` (rising maxParticipants, the last ≥ `Limits.maxUnitSize`, known tiers), `XPLevels` (first 0 XP and level 1,
  both rising, the shipped badge colours), `Profile.avatarPresets` (the shipped pictures). Points must be inside the
  map (`err.setting_outside_map`).
- `Labels` (OPEN, kind `labels`): keys `custody.offence.|profile.commend.kind.|badge.|bonus.|penalty.<id>` whose id
  exists (the config lists, `CP.Scoring.badgeCatalog()` when it exists, or a key of en.json), text 1-64 characters
  without `<`/`>` (`err.setting_label_key|label_unknown|label_text`).
- `MissionTweaks`: every in-game change also asks `CP.Missions.checkTweak(id, tweak) -> ok, errKey` when the missions
  module offers it (never at boot).
- `registerValidator(pattern, fn(path, clean, ctx) -> errKey|nil)`: pattern = a path, `*` segments, or a prefix
  covering everything under it; `ctx = { boot, pending, effective(path) }`. Run on every change (raw editor and every
  structured editor) and on every saved row at boot; a failing validator refuses (`err.setting_check`).
- History: every set, reset, reset all and switch writes a `cp_settings_history` row (`old_json`/`new_json` in the
  cp_settings form, NULL = config.lua's; `by_actor`, `by_ident`, `reason`, `reverts_id`): `history({ path, page }) ->
  { rows, page, pages, total }`, `historyEntry(id)`. `set`/`setMany` opts also take `reason`, `revertsId` and `confirm`.
- Net: `server:admin:setSetting` takes `confirm` and `reason`; `server:admin:setSettings` (`{ changes = { { path, value? |
  json?, none? } }, confirm?, reason? }`) saves several as one.

Full admin control, System (P5):
- Departments: a department added in game is one record setting `Departments.<key>` (a key config.lua does not have;
  `^[a-z0-9_]{1,32}$`; template `Settings._deptRecord`: label, short, enabled, jobs, supervisorGrade, societyAccount,
  theme, logo); `entry()` answers it (`added = true`, nullable: none = deleted), `addedDepartments()` lists them.
  config.lua departments keep one setting per field and gain `logo.url` (https, ≤ 512), `logo.file` (a png/webp/svg name
  in logos/) and `theme.text` (hex), all nullable. `checkDepartments(path, clean, ctx)` is the registered validator for
  everything under `Departments` (raw editor and Departments screen alike): a job in one department only
  (`err.dept_job_taken`), at least one department on (`err.dept_last`); not at boot: a job moved between departments
  while a run or a Cross-Department Mission is going (`err.dept_job_moving`), turning off a department whose officers are
  on one (`err.dept_on_run`), jobs Qbox has (`err.dept_job_unknown`), a supervisor grade of those jobs
  (`err.dept_grade_unknown`), a society account Renewed-Banking knows while `Cash.source = 'society'`
  (`err.dept_account_unknown`).
- `Tablet.desks` leaves the restart list (clients rebuild their zones on `settings:changed`); at most 50, inside the map,
  0.3-5 m a side (`err.desk_size`), known departments (`err.desk_department`).
- More validators: `Retention.auditDays` 0 or ≥ 30, `Retention.runArchiveMonths` 0 or ≥ 3, `Tablet.access.requireItem`
  only with `Tablet.item` set (`err.require_item_none`), `AdminTheme` text at 4.5:1 or more on background and surface
  (`err.theme_contrast`).
- Templates: `Challenge.bounties` (kind `rows`: known kinds, unique, ≥ 1 while `weeklyBounty`), `Goals.daily|weekly`
  (kind `goals`: id, label, count, optional type, mission, stat, unit, crossDepartment, missionCall, enabled; unique ids,
  a known mission type).
- `all()` adds `resets = { daily, weekly }` (the next reset times), `safeMode` and `added`.
- History: `admin:getSettingsHistory` reads `history()` (full values; each row adds `latest`, `label`, `canRevert`,
  `byName`, `oldValue`/`newValue` short texts). `revert(src, historyId, { reason, again, confirm })` sets the row's old
  value again (a reset when it was config.lua's) through every check; a row that is no longer the last change of its
  setting answers `err.setting_changed_since` until `again`. Audit and history action `settingReverted`.
- `export() -> { text, count }` (the saved rows as JSON, never secrets), `previewImport(text) -> view, apply` (≤ 256 KB,
  ≤ 1000 rows; unknown, locked and invalid paths listed and skipped, money switches never turned on by an import),
  `import(src, apply, { reason })` (setMany in groups of 50, audit `settingsImport`).
- Safe start: `set cp_settings_safe 1` in server.cfg: the saved rows are read but not applied for that start (nothing is
  deleted), `set`/`setMany` answer `err.settings_safe_mode`, reset still works, a Config health error says so.
- Console: `CrimsonPoliceAdmin settings` (lists the saved rows), `settings reset <path>`, `settings reset all`.
- Net (P5): `server:admin:revertSetting`, `admin:exportSettings`, `admin:previewSettingsImport`,
  `server:admin:importSettings` (§8.4.5).

### 5.37 CP.AdminKit and CP.Maintenance — modules/adminkit (S)

The one wrapper every new admin action of full admin control goes through, and the maintenance lock. fxmanifest lists
the file by name (so it loads before every module) and again through `modules/**/server.lua`; FXServer runs both, so
the file starts with a load guard (`CP.AdminKit._installed`, as CP.Storage) and the second run changes nothing. Hook names the
packages share: `admin:changed { kind, citizenid?, missionId? }` (each module clears the caches it owns),
`row:voided`, `row:restored`, `row:forfeitUndone` (fired by the corrections package, §5.38), `settings:changed (paths)`,
`maintenance:changed (view|nil)`, `adminjob:progress (AdminJobProgress)`.

**`Kit.action(name, permKey, fn, opts)`** registers `CP.Net.action(name)` (rate `opts.rate`, default 2/s). Guards, in
this order:

| Code | Guard | How |
|---|---|---|
| M | maintenance | refused (`err.maintenance`) while `CP.Maintenance.active()`, unless `opts.maintenance` |
| P | permission | `CP.Access.isAdmin(src)` and `CP.Permissions.can(src, permKey)`: admins and the console; a supervisor never passes |
| L | rate | `opts.rate` per second per player; `opts.targetRate = { n, windowMs, field = 'citizenid' }` = n per window per target across every admin (`Kit.targetOk(name, target, n, ms)` → `CP.Net.rateOk('target', ...)`) |
| I | one request | `opts.requestId`: `payload.requestId` (UUID v4) is inserted into `cp_admin_requests` first (`INSERT IGNORE`); a repeat gets the stored `{ ok, data }` and never acts again (`err.request_busy` while the first runs); a guard that refuses before the action frees the id again |
| R | reason | `opts.reason = true \| 'optional'`: trimmed, control characters to spaces, 1-255 UTF-8 characters (`err.reason_required|reason_invalid|reason_too_long`) |
| T | typed word | `opts.confirm = word \| fn(payload, ctx) -> word`: `payload.confirm` must match, trimmed, any case (`err.confirm_mismatch`) |
| S | self | `opts.self = fn(payload, ctx) -> { citizenid?, runUuid?, strict? }`: refused on any character of the acting admin's license (`err.self_target`) and on any run, live or archived, one of them took part in (`err.own_run`); `strict` (money, points): an unknown license is refused (`err.self_unknown`), otherwise the action goes ahead and its audit reason says "licence unknown". The console is exempt |
| — | the action | `fn(ctx) -> ok, data \| false, errKey`; `ctx = { src, payload, name, reason, requestId, actor, role, target, old, new, audit(action, target, old, new, aopts) -> id\|false, consume(token, kind, ids), changed(kind, cid, missionId), notify(cid, kind, key, vars) }` |
| A | audit | `ctx.audit` writes synchronously (`Admin.auditSync`): a money action writes it **before** money moves and stops when it returns false; `opts.audit` = an action name written after success when fn wrote none (with `ctx.target/old/new`) |
| C, N | caches, toasts | `ctx.changed` fires `admin:changed`; `ctx.notify` toasts an online officer |

V and K are helpers the action calls, because only it knows its ids and old state:
- **V** `Kit.preview(src, kind, ids, effect) -> token, expiresAt` (120 s, bound to the admin, the kind and an order-free
  hash of the ids); `Kit.consume(src, token, kind, ids) -> ok, effect | false, err.preview_missing|preview_expired|
  preview_stale` (used once).
- **K** `Kit.cas(sql, params) -> ok | false, err.state_changed` (an UPDATE whose WHERE names the expected old state;
  exactly one row must change). A money action claims first, audits, moves money, then writes the final state.

Also: `Kit.run(name, src, payload)` (a registered action called directly: the console, tests), `Kit.callback(name,
permKey, fn(ctx) -> data | nil, errKey, opts)` (admin-only reads; `ctx.preview(kind, ids, effect)`), `Kit.reason(v,
optional)`, `Kit.confirmOk(given, word)`, `Kit.isSelf(src, citizenid, strict) -> bool | nil, err` (the character's
license is one of `CP.Access.licensesOfSrc(src)`), `Kit.selfRun(src,
runUuid)`, `Kit.claimRequest / finishRequest / releaseRequest`, `Kit.validRequestId`, `Kit.uuid()`, `Kit.auditSync(src,
category, action, target, old, new, reason, opts)`, `Kit.changed`, `Kit.notify`.

**Day counts from saved rows** (a restart never resets a limit): `Kit.dayStart(ts)`, `Kit.weekStart(ts)` (CP.Schedule's),
`Kit.dailyCount(action, { target, actor, since }) -> n` (cp_audit rows since the daily reset), `Kit.dailySum({
missionIds = { 'manual_adjust' }, actor, column = 'final_points'|'cash_base', since }) -> n` (today's unvoided manual
rows by `breakdown.by`, absolute values summed in Lua).

**J: bulk jobs.** `Kit.registerJob(kind, { batch = fn(job, ids) -> ok, err; finish = fn(job); rollback = fn(job) })`;
`Kit.startJob({ kind, src, reason, ids, filter, detail, id?, wait? }) -> ok, jobId | false, err.admin_busy|job_kind`:
one job server-wide (it takes the busy lock), `cp_admin_jobs` row first (`detail.ids` = the fixed id list), batches
of 50 ids with `Wait(0)` between, `done` saved after every batch and `adminjob` pushed to admin players only
(`CP.Tablet.pushAdmins`). `Kit.job(id)`, `Kit.jobs({ kind, limit })`. At start (5 s after load, once the
migrations are ready) a job left `running` is finished from `done` when its kind is registered, else rolled back
(`rollback`) or marked `failed`; admins get a toast. Per-officer effects are recomputed from rows in `finish`, never
applied as deltas.

**The busy lock** (one long piece of work at a time: a job, a storage copy, a backup, a restore): `Kit.busy() -> kind,
info, since`, `Kit.lock(kind, info) -> ok | false, err.admin_busy`, `Kit.unlock(kind)`, `Kit.withLock(kind, fn, info)`,
`Kit.waitIdle(ms) -> free` (the nightly archive and the forfeiture job wait on it). `Admin.storageCopy` takes it.

**SQL in files mode** (every statement of this build): no ORDER BY/LIMIT on a UNION (wrap it in a derived table), no
UPDATE/DELETE with LIMIT (`WHERE id IN (…50 placeholders)`), no BETWEEN (`>=` and `<`), no HAVING/AVG, `/`, `%`,
window functions or WITH (compute in Lua), no FOR UPDATE (use K), no multi-table UPDATE, no LIKE … ESCAPE (escape `%`
and `_` with a backslash), no `INSERT INTO t (SELECT …)`, one JSON path per JSON_EXTRACT, DATETIME compared with
`FROM_UNIXTIME(?)`. JSON keys that hold a `-` (mission ids) are changed by read-modify-write in Lua with a compare on
the old JSON text. New columns come only from migration 008 (one per statement, no key; both run tables alike).

**`CP.Maintenance`**: `begin(kind, info) -> ok | false, err` (kinds `storage`, `restore`, `left_behind`; another kind
while one is held is refused), `finish(kind)`, `active() -> kind, info | nil`, `view() -> MaintenanceView | nil`,
`askRestart(kind)` (the work is done: `view().restart = true` and one console line "Restart Crimson-Police now from
txAdmin or the server console"; Crimson-Police never restarts itself), `mark(kind, fields)` (merges fields into the
held lock's info and pushes: a restore that stopped part way sets `failed` and `automatic`, shown in the view). Every change is pushed to every client
(`client:push` topic `maintenance`, `false` when it ended) and fires `maintenance:changed`. While held: the net gate
refuses every action not marked `maintenance` (§2), runs, claims, test runs and operation launches refuse at their own
checks, payments, reward delivery and scheduled jobs wait, and the tablet shows the banner.

### 5.38 CP.Corrections — modules/corrections (S)

An admin's corrections to officers' records, all through `CP.AdminKit` (§5.37) and the admin-only keys of §5.3:
signed point adjustments, the bulk void and restore engine, retire and unretire, reset progression, the XP check,
restore run, void kinds, flag by hand, badge overrides, streak and first-run tools, goals, the record move and staff
notices, and the run history an admin reads. Every action and callback is in §8.4.1.

- **Rows, not edits.** A correction writes a new row (an adjustment) or voids rows; nothing is deleted and no old row
  is edited, apart from the void/restore columns of migration 008 (`void_kind`, `void_batch`) and
  `breakdown.cash.beforeVoid` (the cash status at void time).
- **The bulk void engine.** `NormFilter(f)` → `Candidates(f)` (both run tables, `created_at >= FROM_UNIXTIME(?)` and
  `< FROM_UNIXTIME(?)`, never BETWEEN) → `Pick(src, f)` leaves out every run any character of the admin took part in
  (live and archived) → a J job (`Kit.startJob`, kinds `bulkVoid`, `retire`, `restoreBatch`) works on keys `L<id>` /
  `A<id>` in batches of 50 (`WHERE id IN (…)`), writes one `voidRun` / `restoreRow` audit line per row (no webhook)
  and fires `row:voided` / `row:restored` per live row. At the end of every job, and of a job a restart resumed, each
  officer's XP is **recomputed from the rows** (`Scoring.syncXp`) and their badges re-checked. A restore puts rows
  the forfeiture job forfeited because of the batch (`forfeited`, nothing paid, `beforeVoid` held or pending) back to
  `pending` once and fires `row:forfeitUndone` (P4 brings back their item rewards).
- **Kinds of void**: `correction` (a bug or a fix, never a strike) is the default of every bulk void; `strike` counts
  toward `AntiCheat.voidsToSuspend`. `server:admin:setVoidKind` changes it later (K on the old kind).
- **XP** is always `max(0, signed sum)` of the counted rows (completed or failed, not voided, not flagged, live and
  archived): `Scoring.derivedXp(cid) -> xp, rows, sum`, `Scoring.syncXp(cid) -> old, new`.
- **Retire** voids every row as a correction (batch = `cp_officers.retire_batch`), sets `retired_at`, can keep the
  officer off the boards and suspend them; Access refuses a retired officer the tablet (`err.retired`) and their
  picture and bio are hidden from everyone else (never cleared). Unretire restores that batch.
- **Record move** (`recordMove`, `recordMoveUndo` jobs): run rows (both tables), the officer row, badges, overrides,
  commendations, disputes and unfinished item rewards move to the new citizenid; rows keep their department. Refused
  while a row is `paying`, a reward `giving`, either character is online or the target has rows of its own; the
  licenses must match (`UNVERIFIED <cid>` when the old one is unknown).
- **Badge overrides** (`cp_badge_overrides`): `Corr.grantBadge(src, cid, badgeId, reason, opts)` keeps a badge whatever
  the rows say; `Corr.revokeBadge(src, cid, badgeId, reason)` takes it away and blocks it. `Scoring.CheckBadges` and
  the weekly and season jobs respect both (a revoked Officer of the Week is never given again by the catch-up).
- **Staff notices** (`cp_staff_notices`): plain text 1-280 characters, banned words refused, ≤ 30 days, ≤ 5 at once,
  optional departments; `CP.Leaderboard.announcements(dept)` puts them on Home until they expire.
- Exports for other modules: `Corr.grantBadge`, `Corr.revokeBadge`, `Corr.officerRuns(cid, args)`,
  `Corr.runDetail(src, rowId, archived)`, `Corr.officerPoints(cid)`.

### 5.39 CP.LiveCtl — modules/livectl (S; full admin control, live runs, units and anti-farm)

The Admin UI's **Live** screen, an officer's **Today & cooldowns** card and the Missions **Today** card. Every action is
a `CP.AdminKit.action` (§5.37, §8.4.3) with the `liveRuns` or `antiFarmOverride` key (admin-only: supervisors never
pass), a reason, the admin's own runs and characters refused (S), and a synchronous audit row.

- `liveRuns(adminSrc) -> AdminLiveRun[]` (§9.5): every run that has not ended, tests and Cross-Department Missions
  included (`test`, `testBy`, `operationId`, `isBoss`), with `timeAdded`, `timerRunning` and `own` (the viewing
  admin, or one of their characters, is or was on it).
- `officerRunState(citizenid) -> AdminOfficerRunState | nil, err.unknown_officer`: cooldowns (`CP.Runs.cooldowns`
  with type and mission names), today's counts (`completionsToday` raw, per type, the last hour) against
  `Config.Limits` and each type's `dailyLimit`, cash today (`CP.Cash.paidToday`), today's clears and extra runs, the
  boss attempt (`CP.Events.bossUsage`), free abandons of the last 24 h (from the rows: `end_reason = 'real_call'`),
  and, for an online officer, the board as they see it: `CP.Draw.boardCards(src)` reduced to type keys, type labels,
  pool sizes, lock reasons and flags. Mission ids and names never leave in that part (Hard rule Mission choice).
- `clearCooldowns(citizenid, scope, key)`, `allowExtraRuns(citizenid, count)`, `grantBossAttempt(citizenid)`,
  `reclassifyAbandon(citizenid, runUuid)`: the anti-farm overrides. The three markers on `cp_officers`
  (`cooldown_clears = { day, n, all, type = {}, mission = {} }`, `cap_extra = { day, n }`, `boss_extra = { week, n }`)
  are read, changed in Lua and written back with a compare on the old JSON text (K; `err.state_changed` when someone
  changed it since; mission ids hold `-`). The limits come from `Config.AdminControl` and are counted in the saved
  JSON: `cooldownClearsPerDay` clears per officer per day, extra runs 1..`extraRunsMax` once per officer per day,
  another boss attempt once per officer per week; 0 switches a tool off (`err.live_limit_off`). A clear or extra runs
  are refused while the officer is on a run. Treat as a normal abandon calls `CP.Runs.reclassify(cid, runUuid,
  'real_call_cancelled')` (the dodge path: the type and mission cooldowns from now); its own WHERE on `real_call` is
  the compare-and-set.
- `today() -> AdminTodayData`: today's Type of the Day (with the roll and the override), the boss day and the
  twists with their `Config.Events.twists` switches and bonuses. The live run view adds `modifiers` (every twist).
- The sidebar count `adminLive` (admins only) is the number of live runs.

### 5.40 CP.Payments — modules/payments (S; full admin control, economy)
Admin UI → Payments, Departments → Funds and the cash health lines. Every read is a `CP.AdminKit.callback` and every
write a `CP.AdminKit.action` (§5.37): admins only (supervisors never pass), audited. Money moves only through CP.Cash
(§5.20) and CP.Banking (§5.1).
- `list(args) -> PaymentsView` (§9.5): rows with `cash_status <> 'none'`, filters `status` (or `stuck`), `department`,
  `missionType` (`manual_cash` matches the mission id), `citizenid`, `from`/`to` (`>=` and `<`), `page`, `size ≤ 50`;
  each row's owed amount, paid, taken back, the cut of a capped row, the transaction id, account, source and step.
- `totals(args) -> PaymentTotals`: counts, paid and taken back summed in SQL per status and department; owed amounts and
  the cap cut read from the unfinished rows (at most 5000) and every percentage in Lua.
- `export(args) -> { csv, rows, truncated }` (≤ 5000 rows; a cell starting with `=`, `+`, `-`, `@`, tab or CR gets a
  leading `'`; audited `paymentsExport`), `csv(rows)`.
- `departmentFunds(key)`: balance (shown while the source is the server too), paid from the account today / this week /
  this season (rows with `breakdown.cash.source = 'society'`), unfunded rows, admin funding (`cp_dept_funding`) and its
  last 5 rows, the Add funds switch and maximum. Turned-off departments included.
- `sourcePreview()`: per department the balance and the held and pending rows it would pay after a switch to the
  society source. `health()` (registered as ConfigHealth `cash`): a `Cash.account` other than bank or cash, a society
  account Renewed-Banking does not know, a balance below `Cash.lowBalanceWarn`. `lowBalanceToasts()` runs on every daily
  reset (one toast to the department's online supervisors).
- `stuckCount()` (rows in `paying`, cached 30 s) is the `adminPayments` sidebar count (`T.registerNavCount`, admin only).
- Actions and callbacks: §8.4.4.

### 5.41 CP.Sysadmin — modules/sysadmin (S)
Admin UI → System, the Departments tools, positions and Officers → Support (actions and callbacks in §8.4.5). Every
action goes through `CP.AdminKit` (admins only, audited).
- Schema: `schema() -> { order, tables = { [name] = { cols, kinds = dt|date|bool|val, keyset } } }`, built once from this
  version's migration files in an in-memory saves folder engine, so a backup reads and writes the same columns with the
  database on or off.
- Backups: `saves/_backups/` (never served): `index.json`, `<name>.manifest.json` (kind manual|daily|prerestore, time,
  by, version, migration, storage mode, rows per table, files), `<name>.t.<table>.json` (rows as objects; DATETIME as
  unix seconds) and `<name>.f<n>.bin` (custom, archived, edited and deleted mission files named by `cp_custom_missions`,
  department logos, the banned-words file). `backup(src, kind) -> ok, BackupView`, `backups()`, keep `Backups.keep`
  (never the newest or the latest `prerestore`), `Backups.daily` on `CP.Schedule.onDailyJob` (waits for the busy lock,
  then the retention job runs). A part is encoded 1000 rows at a time with a `Wait(0)` between the pieces (LOOP_RULES
  11); the text is the same as one `json.encode` of every row (`[]` for none).
- Restore: `previewRestore(name)` (tables replaced and kept, files, money rows; `err.backup_damaged` as below);
  `restore(src, name, reason)`: refuses while runs go; reads every part it will put back first (missing, not rows, or a
  row without a NOT NULL column that has no default -> `err.backup_damaged`, no lock); takes the busy lock and the
  `restore` maintenance lock, reads the money state (`moneySnapshot(db, { owed = true })`: run rows
  paying/paid/forfeited/capped or with cash paid or taken back, and rows a payment can still reach (held, pending,
  unfunded, or a completed `none` row that carries cash; voided or not), live and archive; item rewards
  giving/given/forfeited and held/pending), makes a `prerestore` backup (`backup(src, 'prerestore', { keep = name })`:
  keep N never removes the backup being restored), writes its name to `cp_storage_meta` key `restore_open` (that table
  is never replaced, so the mark stays with the store it is about), replaces every table except `cp_audit`,
  `cp_settings_history`, `cp_schema_migrations`, `cp_storage_meta`, `cp_admin_requests`, `cp_admin_jobs`, `cp_dept_funding` (and keeps the
  cp_settings rows of the money switches, `AdminControl.*` and `Retention.auditDays`; a NOT NULL column with a default
  that a row lacks, from a backup made before the migration that added it, is left out of the INSERT so it gets its
  default), puts the money state back (`moneyReapply(db, snap, opts)`: the same row is the one with the same id and
  run_uuid whoever holds it, else the same run_uuid and citizenid; item rewards by id + source + source_key + item,
  else citizenid + source + source_key + item; a restore writes the live row's citizenid, cash_status, cash_paid,
  cash_reclaimed, breakdown, voided, void_kind, void_batch, flagged and flag_reason (rewards: citizenid, status,
  given_at); a row the backup lacks comes back whole, under a new id when its id now belongs to another run), writes
  the files back, clears `restore_open`, one audit line (`backupRestored`, critical), then
  `CP.Maintenance.askRestart`. A put-back that fails part way runs `moneyReapply` under pcall, keeps
  `restore_open`, audits `backupRestoreFailed` and marks the lock `{ failed = true, automatic = <name> }`
  (`CP.Maintenance.mark`), and answers `err.restore_failed` (console `sysadmin.console.restore_failed`), or
  `err.restore_failed_money` (console `sysadmin.console.restore_failed_money`) when that `moneyReapply` failed too, as
  the store may hold the backup's money state then; `server:admin:restoreBackup` passes that lock (only that one). At start
  (`startLocks()`, which the migrations runner calls before any module that waits for the store goes on; `_boot()` is
  the same after `CP.Migrations.ready()`, for a runner that did not) a store marked `left_behind` begins that lock and a
  set `restore_open` (a failed restore, or a server that stopped during one) begins that failed `restore` lock again
  (`Backups.holdAfterFailedRestore`, default true; false clears the mark with a console line). While the mark is set the
  money snapshot of a restore is read from that automatic backup's parts (the store may be half put back), the first
  unfinished restore's automatic backup stays named, and it is protected from keep N and Delete. AUTO_INCREMENT
  counters only move up (DELETE never lowers them), so no id is handed out twice. A forced storage copy takes the money
  snapshot (moved money only) of the store it replaces and puts it back after `CP.Admin.storageCopy` with
  `{ ahead = true }`: a row's old money state is written only where it moved more money than the copied row (more
  paid, more taken back, the capped rest paid, or a payment begun; for item rewards giving/given over the rest), so
  the copy never un-pays and never lets a row be paid or taken back twice.
- Storage: `storageView()` (`CP.Admin.storageStatus()` plus `override`, `generation`, `state`, `maintenance`,
  `runsGoing`, `busy`, `backups`), `switchStorage(src, enabled, folder, startEmpty)` (KVP, generation marker in both
  stores, `storage` lock and the restart line), `storageMeta(db?)`; at start a store marked `left_behind` begins that lock.
- Webhooks (read only): `webhooks()` = `CP.Admin.webhooks()` rows (category, convar, state, discord) plus the server.cfg
  line with placeholders; the link never leaves the server. Problems: `CP.Problems.list` with tag and level filters.
  Integrations: each dependency's state and version, the README §7 checklist keys, Crimson-Arena's state, players in the
  arena and its no-build zones (view only).
- Departments: `departmentSetup()` (each department as set now, `added`, `enabled`, the Qbox jobs with their grades and
  who uses them, the cash source); add, save (per field for config.lua departments, the record for added ones), turn
  on/off (typed short tag; officers online get a toast) and delete (added in game, no rows in runs, archive, officers,
  commendations, reports, bounties or funding). Logo upload: base64 chunks of ≤ 16384 characters, one upload per admin,
  ≤ 1 MB in all, dropped after 60 s idle, PNG or WebP by their first bytes (never SVG), saved as `logos/<key>.<ext>` and
  set as the department's `logo.file` (shown after the next restart).
- Desks: add here (the admin's server ped position and heading), update (move here), remove, teleport; `positionOf(path,
  index)` reads a row setting's stored coordinates for Teleport to.
- Support: `checkAccess(src, via)` (`CP.Access.explain` plus the fix key `sysadmin.fix.<error>`), give the tablet item
  (`ox_inventory` CanCarryItem then AddItem; one per 60 s per player, never when they carry one or are in the arena),
  release screen (`client:diagUnstick` to that player only), `clientState(src)` (asks `client:diagState`, waits 3 s).
- Audit exports: `auditPart(filters, part)` (5000 rows per part), `saveAudit(filters)` (≤ 100,000 rows to
  `saves/exports/audit-<time>.csv`), both through `CP.Admin._auditWhere` and `CP.Admin._csv`.
- Console: `CrimsonPoliceAdmin storagemode reset` (also reached as `storage mode reset` through `SUB.storage`).
  Config health check `storage`.

### 5.42 CP.NpcCombat — shared/npccombat.lua and modules/npccombat (client, server)

How hard armed mission NPCs fight back (Config.NpcCombat, the owner's request of 2026-10-19). Config is read at every
call, so a Settings change applies to the next NPC; `enabled = false` makes every function answer the old behaviour
(the weapon as named, 250 rounds, no caps, no damage settings).
- Shared (§2): `weapon(name)` — the name when it is in `weapons`, else `replace[name]`, else `fallback`; never an
  automatic weapon (`AUTOMATIC`: the Automatic flag of gta-v-data-dumps weapons.json), whatever the lists say. Every
  `GiveWeaponToPed` of the resource goes through it: `CP.Runs.spawnPed` and `arm` (also the bag's `cfg.weapon` and the
  capped `cfg.accuracy`, so a new host gives the same), flee_arrest's `DrawWeapon`, `CP.Npc.apply`. `weaponsAllowed`
  is the Builder check of the blocks (while `enabled`, an automatic weapon of an older custom file passes, since it
  is swapped at the spawn; `CP.Missions.normalize` warns once per objective with `automaticsIn`; with `enabled =
  false` the allowed list alone decides, and the Settings entry `NpcCombat.enabled` reloads the missions). The Builder's `builder:config`, Quick edit's pick lists and
  `setMissionTweak` never offer or take an automatic weapon; the Settings checks of `NpcCombat.weapons`, `replace` and
  `fallback` refuse one (`err.setting_automatic_weapon`).
- Client `start(runId)`, `stop()`, `activeRun()`: modules/runs/client.lua starts it at `client:start` and stops it in
  every `Cleanup` (run end, a new start, resource stop). While on: `SetAiWeaponDamageModifier(aiDamage)`,
  `SetAiMeleeWeaponDamageModifier(aiMeleeDamage)`, `SetPedSuffersCriticalHits(PlayerPedId(), false)` (the ped's own
  flag 2 read first with `GetPedConfigFlag`, again for a new ped within 1 s), `SetPlayerWeaponDefenseModifier` when
  officerDefense is not 1.0 (the old value read with `GetPlayerWeaponDefenseModifier`). `stop` resets the AI
  modifiers and puts the flag and the defense modifier back. The 1 s watcher of the run (one thread per `start`,
  ended by `stop`) sets the two AI modifiers again every pass while `reassertAiDamage()`
  (Config.NpcCombat.reassertAiDamage, true, read on every pass; a config.lua that still says `holdAiDamage = false`,
  its name before V2, counts while the new key is missing; false = set at the start and after a respawn only): they
  are one value per game, and another script (Crimson-Contracts' guard scaling) may set or reset it mid-run. `settings:changed` applies a mid-run change at once. A
  foreign `crimsonArena` value of the local player (docs/CRIMSON_ARENA.md rule 8) stops it at once, before the server
  ends the run for that player. Start data with `npcCombat = false` (`CP.Runs.create` opts.npcCombat = false, for V14's
  live runs; `run.npcCombat` is then false) starts nothing; with the field missing it starts as before.
- Client `drop(runId)` and the event `client:npcCombatDrop` (runId): for the active run only, `noCriticalHits` and
  `officerDefense` go back exactly as `stop` puts them back (the ped's own flag 2, the defense modifier read before the
  run) and `a.dropped` keeps them off for the rest of that run (`settings:changed`, a respawn); `aiDamage` and
  `aiMeleeDamage` stay (they act on NPCs only). Idempotent; the next `start` builds a fresh state (protection on again).
- Server (modules/npccombat/server.lua, V8): `dropFor(run, src, why)` sends `client:npcCombatDrop` once per run and
  active participant (logged; false for a run with `npcCombat == false`, an ended run or a non-participant); the memory
  goes at `participant:left` and `run:ended`. V22 calls it for every participant when a volunteer's case is engaged
  (unless `Config.RealSuspects.npcCombat`). A `weaponDamageEvent` handler, always registered and read-only (never
  cancels), returns at once unless `Config.NpcCombat.playerHitDropsProtection == true` (shipped false, read on every
  event): the damage of a player (not an NPC the sender's game moves, as CP.Npc's `ShooterOf`) who is not an active
  participant of the victim's run, on a player ped (`IsPedAPlayer`, owner = `NetworkGetEntityOwner`) who is an active
  participant of an NPC run (not a test, no `run.realSuspect`, `npcCombat ~= false`) -> `dropFor(run, victim)`.
- The `crimsonPoliceRun` player bag (replicated, exactly `true`): `CP.Runs.create` calls `runStarted(run, src, on)`
  right after each `client:start`, and `on` (start data without `npcCombat = false`) sets it; it is cleared (`nil`) at
  `participant:left` (any reason, a disconnect included), `run:ended` and resource stop. Written only on a change
  (`flagRun(src)` names the run it was set for). Crimson-Contracts (its VC1/VC1b `onCrimsonPoliceRun`) leaves the
  shared AI damage value alone while it is true (or while our `crimsonArena` flag is on), so the two scripts never set
  it against each other once a second on a run that has no `crimsonArena` flag (before arrival, after
  `CP.Alerts.releaseRun`). docs/INTEGRATIONS.md, Crimson-Contracts.

### 5.43 CP.Spawn — modules/spawn (client, server)

What this officer's game can see of the points the server's spawn director may use (Config.Spawning.preferHidden,
§5.10, owner request of 2026-10-19: no one spawning in front of or around the officers).
- `visible(points, budgetMs) -> { boolean }` — one answer per point (at most 32; `{ x, y, z }` or `{ [1], [2], [3]
  }`): `false` when every line of sight from the officer's eyes (his head bone SKEL_Head 31086 and
  `GetFinalRenderedCamCoord`, the camera he sees through) to 1.0 m and 1.7 m above the point hits something
  (`StartShapeTestLosProbe` flags 1 + 2 + 16: the map, vehicles, objects; options 7; his car, else his ped,
  ignored), else `true`: one clear line, a probe that did not start (handle 0), an invalid result (status 0), a probe
  still running when `budgetMs` (kept to 50-5000, default 5000) ran out, or an entry that is no point. Probes run
  asynchronously, at most 16 at once, polled each frame with `GetShapeTestResult`; the ones still running at the
  end are read for up to 60 more frames in a thread so the game frees their handles. Needs a thread (`Wait(0)`).
- The ox_lib callback `crimson-police:client:spawn:visible` (§8.1) answers the server's `{ points, ms }` with
  `visible(points, ms)` (`{}` for args that are no table, and when it raises: one `CP.warn`).
- `walkIn(car, ring, budgetMs) -> { { x, y, z, hidden } }` (PLAN S12, Config.Spawning.contactRing): where a returning
  driver or a thief appears for the car at `car` (`{ x, y, z }`). Round the car, in the direction this officer looks
  (`GetFinalRenderedCamRot(2).z`, else his ped's heading) and 25, 50 and 75 degrees either side, at ring[1], halfway
  and ring[2] (ring kept to 5-100 m), `GetSafeCoordForPed(x, y, car z + 1.0, false, 4 + 8)` (no navmesh from a
  building's inside, none in water; found as true or 1); a navmesh point is kept when it is 2D within the ring from the
  car, ring[1] or more from him, at most 90 degrees off his view and 2 m or more from one kept already. Its z is the
  navmesh's + 1.0 (a standing person's point). `visible(kept, budgetMs)`: hidden ones first, then seen ones, each in
  that order, at most 8. Empty when nothing fits. Needs a thread.
- The ox_lib callback `crimson-police:client:spawn:walkIn` (§8.1) answers the server's `{ car, ring, ms }` with
  `walkIn(car, ring, ms)` (`{}` for args that are no table, and when it raises: one `CP.warn`).
- `probe(kind, x, y, z, h, model, opts) -> result` — whether the point is fit to put a `'ped'`, a `'vehicle'`
  (`model`: its name or hash, for its size) or a `'prop'` (`'object'` and any other kind) on, heading `h` (PLAN S6,
  Config.Spawning.ground; the Check spawn points tool calls it, §5.27, and the placer below). Needs a
  thread. Coordinates are sent to the game as decimals. In order:
  1. collision: `RequestCollisionAtCoord` each frame until `HasCollisionLoadedAroundEntity(opts.entity or
     PlayerPedId())` or `Config.Spawning.collisionTimeoutMs` (kept to 500-30000 ms; `result.loaded`);
  2. interior: `GetInteriorAtCoords` ~= 0 and not `IsInteriorReady` -> `PinInteriorInMemory`, wait for it up to
     `interiorTimeoutMs` (500-30000 ms); never ready -> `interior_not_loaded` (nothing else probed); the probe unpins
     only an interior it pinned;
  3. ground: `GetGroundZAndNormalFor_3dCoord` from z + 2.0 (the highest ground under the point) and from z + 50.0
     (a roof or a bridge over it: `result.roofZ` when that is over z + 2; the ground over a point buried deeper than
     2 m when the first finds nothing), retried each frame with `RequestCollisionAtCoord` until either finds ground
     or the collision deadline passes; none -> `no_ground`. When the z + 2.0 look found a surface over z + 0.1 (a low
     roof or the floor above over a person inside, a garage deck over a car, or the ground over a buried point), a
     third look from z + 0.1 finds the ground right under the point: the point stands on the one it needs the
     smaller move to (0 inside its range, as in 5; the one under it on a tie), and then the surface over it is
     `result.roofZ`. A vehicle's model is sized (as in 6) before this choice;
  4. water: the Builder's check (`TestProbeAgainstWater` z + 2.0 to z - 1.5, or `GetWaterHeight` over the ground +
     0.1) -> `in_water`;
  5. height: dz = z - groundZ inside the kind's range (`pedAbove` -0.3..1.6, `vehicleAbove` -0.2..1.5, `propAbove`
     -0.1..0.5; read live, the default when a range is not two ordered numbers) -> `ok`; outside it -> `snap` when
     |groundZ + lift - z| <= `snapWithin` (0-10, default 3.0; lift: a person 1.0, as the Builder stores a standing
     ped; a vehicle -min.z of `GetModelDimensions`, 0.2-1.5; an object 0.0), else `underground` (dz under the range)
     or `floating` (over it);
  6. wall (a ped or a vehicle that is ok or snap, unless `opts.wall == false`: a marker an officer walks to, where a
     door may stand in the space): the Builder's capsule on the ground at groundZ
     (`StartShapeTestCapsule` flags 1 + 2 + 16, options 7: a person 0.45-1.7 m, r 0.32; a vehicle along its heading,
     sized from its model, loaded for it with `RequestModel` and let go again when it was not loaded, a car of
     unknown size `{ lift 0.5, half 2.3, r 0.8, midZ 1.0 }` otherwise; ignoring `opts.ignore`, else his car or his
     ped), polled up to 1 s; a hit -> `in_wall`; not started, lost or unfinished = not known (`result.wall` nil, an
     unfinished one is drained like the line-of-sight probes).
  `result = { status, kind, x, y, z, groundZ, dz, normalZ, roofZ, interior, loaded, water, wall, sized, lift }`: `z`
  is where to put it (the point's own z, or groundZ + lift for `snap`); `sized` (vehicles) whether the model gave its
  size; `lift` (once the ground is found) how far the entity's point sits over the ground (5). A point whose x, y or z
  is no number answers `{ status = 'no_ground' }` without asking the game.
- The placer (PLAN S9, Config.Spawning.place; the server's side, which writes the ask, is below): an
  `AddStateBagChangeHandler('cp', nil, ...)` of its own. A bag of an entity (`entity:<netId>`) with `place
  = { x, y, z, h?, kind, token }` (§6.2) of the run this player is on (`CP.Runs.current().id == bag.run`), whose token
  (a string or an integer) this game has not taken yet, and x, y, z numbers, starts one placement (a bag with no
  `place`, or dead, forgets the net id's token; a run's end, `client:runEnded`, forgets its asks and a placement still
  running for it tells nothing). In a thread: the entity must exist here within 3 s (`NetworkDoesNetworkIdExist` /
  `NetworkGetEntityFromNetworkId`; not streamed here: nothing, its bag comes again when it streams in); this player
  must be an active participant (`status == 'active'`). Who places it: the game that controls it
  (`NetworkHasControlOfEntity`, or `NetworkGetEntityOwner` is this player); when another participant's game controls
  it, that one; when a bystander's or nobody's does, the participant nearest to the point of the ones whose ped this
  game has (the lower server id on a tie). An entity more than 3 m (flat) from the ask's x, y, and from `place.from`
  when the ask has one, has been placed and let go already (a game that placed it could not tell the server: its
  player left the run): it is neither frozen nor moved, `'placed'` with reason `'moved'` and z its height now. Else it
  tells the server it checks the entity (`server:spawnChecking`, §8.2, once per token), so the ask's time waits for
  it; when it then gives up with no answer (its turn never came, this player left the run, control not given or lost,
  the entity gone, or a raise) it sends one more `server:spawnChecking` with `done = true`, so the ask's time runs on
  at once instead of after the whole check time. At most 4 placements run at once (the rest wait up to
  30 s; the slot is taken before control is asked for), each with control (asked with
  `NetworkRequestControlOfEntity` for up to 2 s; not given: no answer, only the `done` word above; a later write
  of the bag tries again). Then
  `FreezeEntityPosition(ent, true)`, `SetEntityLoadCollisionFlag(ent, true)`; a person in a vehicle
  (`IsPedInAnyVehicle`) or anything attached (`IsEntityAttached`) is not moved: `'placed'` with reason `'seated'` /
  `'attached'`; else, when it stands more than 3 m from x, y (an ask the server moved to another point: it waits at
  `from`), `SetEntityCoordsNoOffset(ent, x, y, z, keepTasks = a person, false, true)` first, so the collision loaded
  and probed is the one around it there; then `probe(kind, x, y, z, h or GetEntityHeading, GetEntityModel for a
  vehicle, { entity = ent, ignore = ent })`. Seated or attached by the time the probe ends (the server seats a
  pursuit's, an escort's or a transport's people right after it makes them), or more than 3 m from x, y (the server
  set it somewhere else during the check): not moved, let go (but an object or a cuffed person), `'placed'` with
  reason `'seated'` / `'attached'` / `'moved'` (z its height) (`kind`: `place.kind` 'ped' / 'vehicle' / 'object', else `GetEntityType`). ok or snap: with
  control still held (else no answer, only the `done` word), `SetEntityCoordsNoOffset(ent, x, y, groundZ + lift,
  keepTasks = a person, false, true)` at the server's x, y (it never picks another spot), `SetVehicleOnGroundProperly` for a
  vehicle, `PlaceObjectOnGroundProperly` for an object, and the entity is let go (`FreezeEntityPosition(ent,
  false)`) except an object and a person whose bag is now in the `cuffed` state (CP.Npc holds that pose frozen; a
  later write of the same ask updates the state): `'placed'`. Any other status: it stays frozen, not moved: `'bad'`.
  Told with `server:spawnPlaced` (§8.2) `runId, { netId, token, result = 'placed'|'bad', reason (the probe's status,
  or 'seated'/'attached'/'moved'), groundZ, dz, z (where it was put; nil for bad) }`, once per token; a raise is one
  `CP.warn`, no answer, only the `done` word.
- `CP.Spawn.holds(entity) -> bool`: true while the entity waits for its placement: its cp bag
  (`Entity(entity).state.cp`, not dead) carries a `place` with a token and this game has not put it on the ground
  for that token ('placed'; a bad point keeps it held). CP.Npc's host game never lets such a person go
  (modules/npc/client.lua `LetGo`, used by `Release` and `kneel`, §5.11): the game that places him does, or the
  server when it takes an answer or gives up (below), so a host whose game has no ground loaded where he stands does
  not drop him through the map while another game checks his ground. CP.Npc lets him go itself once the ask is gone
  (the host loop).
- Server (PLAN S10, owner request of 2026-10-19: "i do not want them spawning in the ground"; a1 G3: a far game with
  no ground loaded may simulate a new ped first). `CP.Spawn.ask(run, netId, entity, kind, opts) -> place|nil`, called
  by the engine's Track for every new mission entity (§5.10; `kind` 'ped' / 'vehicle' / 'object'): with
  `Config.Spawning.enabled` and `place` on, and `opts.coords` a point, it sends `FreezeEntityPosition(entity, true)`
  (a server RPC: FXServer keeps it for the first game that takes an entity nobody simulates yet, ServerRPC.cpp),
  keeps the ask `{ x, y, z, h, kind, token }` (the file's point; the token unique per ask, a string) with up to 8
  other points from `opts.alt`, and returns it for the bag (§6.2). `CP.Spawn.waiting(runId) -> n` counts the
  entities of a run that still wait. A check every 500 ms (a thread that runs while any ask is open): an ask whose
  run ended, or whose entity is gone, dead or no longer the run's, is dropped; with place (or enabled) switched off in
  Settings every waiting entity is let go; the game that simulates it (`NetworkGetEntityOwner`: a player's server id,
  -1 = nobody) changed to one that is not an active participant's within `activateRange` (2D) of the point: frozen
  again (the freeze reaches that game; the entity is marked so a later answer also lets it go from here); the time
  (`placeTimeoutMs`) only runs while an active participant is within `activateRange` of the point, so an entity
  nobody is near (staged ahead, a van coming in) waits frozen without a limit, and not while an active participant's
  game has said it checks the entity (`server:spawnChecking` for the ask's current token, taken once per token: the
  placer's turn in a big wave, its control asks and the probe's loads, at most 34 s + `collisionTimeoutMs` +
  `interiorTimeoutMs`, each kept to 500-30000 ms, and only while that participant stays on the run; a new token
  after a bad point clears it, and so does that game's `done = true` word when it gives up with no answer, while a
  later checking word for the same token is still not taken); past it `onTimeout`: `'unfreeze'`
  (default) lets it go where it stands, `'delete'` (never for an ask of `CP.Spawn.again` below: a person or
  vehicle the server only moved, a warrant's suspect who gives up at the door or the prisoner transport put on its
  parking point, is always let go where it stands) counts it as gone (`Runs.entityDied`, the objective's
  `onEntityDead`) and deletes it, with one `CP.warn` (`run <id>: ped <model> at x y z was not placed by an officer's
  game within 8000 ms; let go where it stands (Config.Spawning.onTimeout)`).
  The answer, `server:spawnPlaced` (§8.2, at most 30 a second per player): taken only from an active participant of
  that run, for an open ask with that net id and its current token; anything else is ignored. `'placed'`: refused
  (one `CP.warn`, the ask stays open) when its `z` is more than `ground.snapWithin` + 2 m from the ask's z (reason
  `'moved'` is not checked: it stands where it ran to); else the ask is over: `place` leaves the bag
  (`CP.Npc.setPlace`, else the engine's copy), and the entity is let go from here when the server froze it again
  after an owner change, when the game left it as it was (reason `'seated'`, `'attached'`, `'moved'`), or when it is
  an object made with `frozen = false`; an object otherwise stays frozen, and a person CP.Npc holds cuffed is never let
  go from here. `'bad'` for a person the server sees seated in a vehicle (`GetVehiclePedIsIn`; seated after his game
  checked his ground): the ask is over, he is let go, one `CP.log`. Any other `'bad'` (in a thread of its own): while fewer than
  `Config.Spawning.retries` other points were tried, the next of its other points that is free (no entity of the run
  within 1 m, not another waiting entity's point) and that the director allows now (`Runs.choosePoints(run, free, 1,
  { obj })`: the distance and behind rules from where the officers stand by then) becomes the ask: x, y, z, h of
  that point, a new token, `from = { x, y }` of the point it waits at, its time back to 0 (the officer's game moves
  it there and places it; the same entity, so the objective that made it keeps counting it); one `CP.warn` `run <id>:
  ped <model> at x y z is underground (ground 31.40); used spawns[4] (70.00 170.00 31.00) instead`. No such point, or
  the retries spent: the ask is over and the entity is let go where it is (as before), one `CP.warn` ending `used it
  there (no other point allowed)` / `used it there (Config.Spawning.retries = 2 spent)`.
  `CP.Spawn.again(run, netId, coords, from) -> place|nil` (PLAN S11): the server moved a live person (or vehicle) of
  the run itself (flee_arrest's surrendering suspect, stood at the door step with `SetEntityCoords`): with place on it
  freezes him, replaces any open ask with one at `coords` (a new token, no other points: a bad answer lets him go where
  he stands with one warning), `from = { x, y }` where he stood before (the placer moves him to `coords` first when
  the server's move has not reached its game), writes it to his bag and returns it; nil when place is off or he is not
  a live entity of the run. `CP.Spawn.holding(netId) -> boolean` (PLAN S12): true while an ask for that entity is open
  (it waits frozen; field_contact walks a returning driver or a thief to his car only after that).

### 5.44 CP.Markers — modules/markers (client)

The current objective on this officer's map (Config.Markers, the owner's request of 2026-10-19: "ensure all objectives
as they come up mark on the map"; PLAN M1, BLIPS_FINAL R1-R10). One pointer per officer: a blip, or a circle with its
centre, and at most one GPS line. modules/runs/client.lua drives it: `client:objective` `start` → `set(runId, index,
msg.marker, ctx)` after the block's own `start` (ctx = the block's client ctx, for Radio Silence), `client:marker` →
`update` (only for the current, started objective of this run), `stop` → `clear(runId, index)` before the block's
`stop`, and every `Cleanup` (run end, leaving, a new start, resource stop) → `clear()` before the blocks stop (`clear()`
without arguments also removes the run's service vehicles, PLAN M7).
- The marker (from the server, §5.10 `marker`; nil = none): `{ kind = 'point'|'area'|'targets', look, label, key,
  number, coords = { x, y, z }, radius (area), route = true|false|'block', targets = { { key, netId, x, y, z, look,
  label, variant, number, beyond } } }`. `look` is a `Config.Markers.kinds` key (default `'objective'`, an area
  `'searchArea'`); `variant` `'boss'|'next'|'followUp'|'setback'|'surrendered'` picks the kind's bossScale, nextScale,
  followUpColour, setbackColour or surrenderedScale (R6: 0.6 when the kind has none; the server's flee_arrest,
  search_area and pursuit markers send `'surrendered'` for one who gave up, and their blocks style their own blip with
  it, so he is one size near and far). `beyond` (metres, PLAN M3): this target takes the line before the others while this officer is
  farther than that from it (kept until he is within 75 % of it), and never closer: then the others share it (escort:
  the truck while HE is farther than clearRadius from it, else the destination; BLIPS_FINAL X17, decided in each
  officer's game). `route = false`: no line; `'block'`: the block keeps its own line (checkpoint_route), CP.Markers
  draws none. At most 32 targets.
- One icon per target (R1): `adopt(key, blip)` — a block hands over the blip it draws for target `key` (a net id or a
  point index, the marker's `key`): that blip is the pointer, CP.Markers draws no icon of its own for it and only sets
  its line, `SetBlipPriority` and one flash; a blip handed over while CP.Markers' own icon of that target is still
  flashing flashes for the rest of that one flash (a block draws its blips from its first snapshot, just after the start
  message's pointer). `release(key, blip?)` — the block takes it back before removing it: its line goes off and
  CP.Markers draws the target again; with `blip`, only when that is the blip handed over for `key`. Used by
  interact_points (each pending or follow-up point's numbered blip in kinds.point, followUp while it needs a follow-up,
  key = its point number; a hidden search's centre in kinds.searchArea, key `'area'`, its circle in `styleArea`; PLAN
  M6: a snapshot keeps every blip that still shows the same point, a changed status is restyled in place, R8),
  skill_check (PLAN M6: each device still to work, armed, set back or waiting to be tried again, numbered in
  kinds.device, setback while set back, restyled in place, key `'d<n>'`; kept across snapshots, R8; PLAN M7: named
  after the mission's target (`obj.target.label`, Drug Lab Raid "Shut down the lab"), else `block.skill_check.blip`
  "Device {n}", set back `block.skill_check.blip_setback` "{action} {n}" ("Ventilate 1"), the server's marker naming
  each the same; a set-back blip flashes until it is fixed, `SetBlipFlashes(false)` when it is restyled out of
  setback), process_scene
  (PLAN M6: the scene's blip in kinds.scene, key `'scene'`), checkpoint_route (PLAN M6: the current checkpoint's
  numbered blip in kinds.checkpoint, key `'cp<n>'`, the next one at nextScale; the marker says `route = 'block'`, so
  the block keeps its own line on that blip, in `routeColour()`, on only while `canRoute(ctx)` allows one: checked
  when the checkpoint changes and once a second in its loop, the route natives only when the answer changes; this ends
  the second line a late partner had while still driving to the start), pursuit (each live car's blip in kinds.vehicle and each suspect's out of the car in kinds.suspect, key
  = its net id; the observe violator only once it passed; PLAN M7: a suspect running on foot in kinds.fleeing,
  restyled in place when he stops, fights or gives up (surrenderedScale), and the server's marker gives him the same look) and escort (the truck's blip in kinds.escort, key = its net
  id; the destination's in kinds.destination, key `'dest'`; the attackers' red dots stay detail blips), flee_arrest
  (PLAN M4: the front door's blip before the knock, key `'door'`; each suspect's, associate's or inmate's in
  kinds.fleeing while he runs, else kinds.suspect, a surrendered one at surrenderedScale, restyled in place when his state changes,
  key = his net id), protect_rescue (each hostage's in kinds.hostage, key = his net id; the safe point's in
  kinds.safePoint, key `'safe'`) and field_contact (each contact's, key = its net id: a car in kinds.contactVehicle, a
  person in kinds.contact, kinds.fleeing while he runs, kinds.suspect once he draws or gave up, restyled in place) and
  search_area (PLAN M5: the circle's centre in kinds.searchArea, key `'center'`, its circle in `styleArea`, a shrunk
  circle's new centre handed over before the old one goes; each clue's numbered blip in kinds.clue, key `'c<n>'`; each
  fugitive's in kinds.fleeing while he runs, kinds.suspect at surrenderedScale once he gave up, restyled in place, key = his net
  id). An adopted blip that no longer exists falls back the same way at the next check. `clear` hands every adopted
  blip back with its line off. CP.Markers draws its own icon only for what no block draws: a fight area (hostile_waves,
  PLAN M5: kinds.fightArea, a red skull and circle named `markers.fight` "Hostiles"), a fallback anchor, a target not
  streamed here, and service vehicles. Detail blips that are never handed over are still styled with `style`, so
  they follow `shortRange` too: hostile_waves' hostiles (PLAN M7: kinds.hostile, a boss at bossScale named after
  `obj.boss.label` with its first letter upper-cased, else `block.hostile_waves.boss_label`).
- Own icons: a point or an area's centre `AddBlipForCoord` (an area adds `AddBlipForRadius`, colour of its kind,
  alpha `areaAlpha`); a target `AddBlipForEntity` while `NetworkDoesNetworkIdExist(netId)` and the entity exists here,
  else (`farTargets`) `AddBlipForCoord` at the server's position, moved with `SetBlipCoords` on every update, swapped
  for the entity blip once it streams in and back once it streams out (R7). Unchanged elements keep their blip, line
  and flash (R8); a new look, label or number redraws the blip.
- `style(blip, kind, label, opts)` — the look of `kinds[kind]` and what every objective blip gets (R5):
  `SetBlipSprite/Colour/Scale`, `SetBlipAsShortRange(shortRange)`, `SetBlipCategory(category)`, `ShowNumberOnBlip`
  for `opts.number`, the name (`BeginTextCommandSetBlipName('STRING')`); `opts.variant = 'setback'` also starts
  `SetBlipFlashes(true)` with no timer while `setbackFlash` is on (PLAN M7: a set-back device flashes until it is
  fixed; the block stops it). The pointer also gets `SetBlipPriority(12)` and flashes once, `SetBlipFlashes` +
  `SetBlipFlashTimer(flashSeconds * 1000)` (none at 0; none on a set-back target, which already flashes).
- `styleArea(blip, kind)` — a block's own circle (`AddBlipForRadius`) in the colour of `kinds[kind]` at `areaAlpha`, as
  CP.Markers draws its own circles (search_area, PLAN M5; interact_points' hidden search, PLAN M6).
- `routeColour() -> integer` — `Config.Markers.routeColour` (0-85, default 5): the colour of every Crimson-Police GPS
  line, a block's own included (checkpoint_route, PLAN M6).
- The line (R2, R6): on ONE blip, the one the pointer leads to (`cur.pointed`: of what the map shows, the point or
  centre, or this officer's nearest target, moved only when another is 25 % closer; a target with `beyond` first while
  he is farther than that from it; kept while the line is off, so the HUD line and Objective GPS name the same one),
  `SetBlipRoute` + `SetBlipRouteColour(routeColour)`; off within `routeOffWithin` of a point or target
  and inside an area's radius. `canRoute(ctx)` — false while `enabled` or `route` is off, under Radio Silence, while
  `CP.Route.current()` exists and has neither arrived nor switched to the action (CP.Route samples the start's line
  from the blip-route slot first, §5.12; a late partner's `action`, PLAN M11, comes after CP.Route dropped the start's
  line), and while the officer has a waypoint (`IsWaypointActive`: his own, or the one Objective GPS set). Every blip
  CP.Markers removes or hands back loses its line first (R10). `leads(ctx) -> boolean` — whether an objective line can
  show at all for ctx's run (`enabled` and `route` on, Radio Silence not hiding lines): CP.Runs asks it before a late
  partner's game drops the start (`CP.Route.follow(runId, dropStart)`).
- The HUD line (PLAN M10, `Config.Markers.hudLine`): each check sends `CP.Tablet.hud({ target = { label, distance,
  inside? } })` for what the pointer leads to (its label, else `markers.objective`; `distance` in metres to the point,
  the target or an area's edge, in 10 m steps under 1 km and 100 m steps above; `inside` = within an area's radius),
  only when that changes, and `{ target = false }` once when there is none: nothing shown on the map (Radio Silence
  included: no distance to a suspect it hides), the officer still driving to the start, `hudLine` or `enabled` off, and
  at every `clear`. The NUI shows it under the objectives while `phase` is `'objectives'` (§9.3).
- `objectiveGps() -> ok, { label } | errKey` — the client action `setObjectiveGps` (PLAN M10, registered with
  `CP.Tablet.registerClientAction` once every module has loaded; payload ignored): `SetNewWaypoint` on what the pointer
  leads to, its line off at once (the waypoint is the officer's one line, R2) and a toast `markers.gps_set`. Refused
  with `err.objective_gps_off` (`objectiveGps` or `enabled` off), `err.objective_gps_none` (nothing on the map),
  `err.objective_gps_start` (still driving to the start: the start keeps his line) and `err.objective_gps_silence`
  (Radio Silence hides the line: `'area'` or `'none'`). While the waypoint stays ours (`GetFirstBlipInfoId(8)` within
  15 m of where we put it) each check moves it to the pointer once that is more than 50 m off (a moving car or suspect,
  the next nearest door); `clear` (the objective's stop, the run's end) and a `set` for another objective remove it
  (`SetWaypointOff`). A waypoint the officer put in its place is never moved or removed.
- `hidden(ctx, kind, variant?) -> boolean` (R9, PLAN M8): true when Radio Silence (`ctx.radioSilence`; nil ctx = the
  current pointer's) hides a block's own blip of `kind` (a `Config.Markers.kinds` key, or `'route'` for a GPS line) by
  `Config.Markers.radioSilence` (an unknown value counts as `'area'`). Every block client asks it before it draws a
  blip or a line (checkpoint_route, search_area, pursuit, flee_arrest, escort, hostile_waves, protect_rescue,
  interact_points, skill_check, process_scene, field_contact) and drops a blip it now hides: `'none'` hides everything
  but `start`, `prisonerVan` and `towTruck`; `'area'` (shipped) hides `'route'`, the `'next'` variant (a second
  checkpoint), `point` and `device` (CP.Markers shows the nearest itself, below) and every kind but the objective's
  circle or one point (start, checkpoint, searchArea, fightArea, destination, safePoint, scene, objective and the
  service vehicles); `'full'` hides nothing. The block server markers send the same pointer with or without Radio
  Silence (interact_points and skill_check sent none before M8); search_area keeps its circle as the pointer once
  inside unless the mode is `'full'`. CP.Markers' own pointer under `'area'`: it hides every target that has a `netId`
  (a person or a car), whatever its look (a target without a look gets `objective`); of several points it still shows
  (Business Check's doors, Bomb Disposal's devices) it shows only this officer's nearest (`cur.single`, moved only when
  another one is 25 % closer); with `radioSilenceLastKnown` > 0 a hidden moving target gets a 200 m circle
  (`markers.last_known`) where it was, moved every that many seconds.
- `service(key, spec)` — a prisoner van or tow truck coming to this officer: `spec = { netId, coords, kind =
  'prisonerVan'|'towTruck', label }`, nil removes it. Shown in every Radio Silence mode while `serviceVehicles` is on,
  never routed, removed by `clear()` (the run's end) and at resource stop. modules/custody/client.lua calls it (PLAN
  M7) from `client:serviceBlip` (key `service:<id>`, only for the officer's current in-progress run and the two
  kinds); the server (modules/custody/server.lua `SyncBlip`, in its 1 s tick) sends that to every active
  participant when a transport van's or tow truck's status changes: shown while coming, parked or loading (at the
  server's position; the client follows the vehicle once it streams in), off once it leaves or is gone; `run:arrived`
  sends the ones on the map to a late partner. The coroner van stays unmarked; a vehicle never made sends nothing.
- One check loop (1 s) only while a pointer element or a service vehicle is on the map, never two (it ends by itself
  after `clear`): streaming swaps, adopted blips that went, the nearest target, the line, the HUD line (sent on change
  only) and the Objective GPS waypoint. No entity pool scans.

### 5.45 CP.Opponents — modules/opponents (S)

The real suspects of a case, shared by live crimes (§5.46) and volunteer suspects (§5.47); the owner's decision of
2026-10-26, "Build all 3 but options in the config.lua". A case belongs to one run and one objective; each suspect is
keyed by citizenid and carries his state (free, cuffed, detained, booked, lost, left or void), the proof the server
checks before anything scores (the sc-police cuff pair and custody hold, bookings, downs: V5), the officers' conduct
ledger (V6), the identity and pair rules (V7), a position trail and a timeline for review, and staff notes that never
hold points. Nothing opens a case yet (V14 and V22 do), so nothing runs while Config.LiveCrime.enabled and
Config.Volunteers.enabled are false (both shipped false). Rules: Config.RealSuspects. Built in steps V4-V26
(/tmp/claude-0/-home-user-PoliceTablet/c9b2f5e1-32ec-5436-a1db-2a78c5b9aa69/scratchpad/pvp/DESIGN_FINAL.md).

Core (V4, modules/opponents/server.lua). Times inside a record are GetGameTimer() milliseconds; `t` in the timeline,
notes and trail and `case.openedAt` / `closedAt` are os.time() seconds (`case.openedMs` is the GetGameTimer() of
the open).
- `case = { runId, run, kind = 'live'|'volunteer', index, openedAt, openedMs, scene, lostRule = { range, seconds }|nil, meet|nil,
  suspects = { [cid] = rec }, order = { cid... }, timeline, ledger, trail = { [cid] = ring }, notes, crimeEndedAt }`;
  `rec = { cid, src, license, label = 'A'|'B'|... (shuffled with CP.U.rng(run.seed), C5), state, since, contactAt,
  lastContactAt, lastCoords, md = { ishandcuffed, isdead, inlaststand, injail }, down, downAt, protectUntil, cuff,
  outsideCuff, cuffedAt, detainedAt, bookedAt, injailAt, jail, share, caughtBy, armedUntil, everArmed, firstHitAt,
  lastHitAt, conduct, penalized (V6), afk (true = AFK by his samples), near, dropAt, leftAt, byLeave, notes,
  outcome }`.
- `open(run, spec) -> case|nil`: `spec = { kind, index, members, scene, lostRule, meet }`; `members` is a list of
  citizenids or a map keyed by them (`{ [cid] = true }`, or Crimson-Contracts' `{ [cid] = src }`: the server ids in
  it are never read, C9). Each src comes from `CP.Qbx.getByCitizenId` and one `getInfo` (license, the metadata mirror)
  at open. A suspect who is offline starts in the disconnect-grace path (src nil, dropAt now, the license read in a
  thread with `CP.Qbx.licenseOf`; critic 2 #19). A citizenid that is a suspect of another case is left out. A second
  open of the run returns its case.
- `close(run) -> { [cid] = outcome }, case`: 'detained', 'booked', 'got_away' (free, cuffed with no detain, lost),
  'left', 'void', or the outcome a later step set. A leave still waiting for its grace (a drop, or offline since the
  open) is made final first, as below (the onLeave rule or cuffed -> detained, and the `rs_combat_log` note), with no
  objective event, so a suspect who logs off just before End case, the time limit or the last officer leaving is
  never 'got_away' by the leave. The `run:ended` hook closes the case; a second call for the same run (another
  `run:ended` listener) answers the same outcomes (the last 16 closed cases are kept).
- `active()` (true while a case is open; the V3 facts only pass then), `caseOf(run)`, `bySrc(src) -> case, rec`,
  `byCid(cid) -> case, rec`, `view(run)` (a copy for blocks with no server ids: label, state, online, contact, down,
  afk, share, byLeave, everArmed, outcome, md), `nearAny(run, coords, range) -> true, cid, metres` (a free or cuffed
  suspect at the last watch pass; no native read), `crimeEnded(run)`, `noteArmed(cid)`, `trailOf(run, cid)` (oldest
  first), `setState(run, cid, state, { event, why, by })` (for the proof step), `send(run, cid, kind, extra)` (a
  server-only event that is not a state change: opp_down, opp_up, opp_cuff_attempt), `timeline(run, entry)` (a staff
  timeline line), `onTick(fn)` (fn(case, now) once per case on every watch pass, after the suspects), and two fields
  the proof step sets: `onMeta` (`fn(rec, key, old, new, case)` after the mirror changed) and `onClose`
  (`fn(case)` at the close, before the outcomes are read).
- `eligible(src, opts) -> ok, reason` (events and claims only, never per tick), refused in this order: `not_loaded`
  (no getInfo), `in_case`, `instance` (bucket other than 0), `arena_flag` (CP.Alerts.foreignFlag), `on_duty` (on duty
  in a Config.Departments job), `job_hop` (`Opp.lastPoliceAt(cid)` from V7, os.time(), within jobHopMinutes; nil
  until V7), `afk`; with `opts.intake` also `no_position`, `no_start_zone`, `down`, `cuffed`, `jailed` (metadata);
  then `excluded` (`IsPlayerAceAllowed(src, excludeAce)`, a server BOOL native: truthiness) and `admin`
  (`CP.Access.isAdmin` while `excludeAdmins` is not false; critic 2 #29).
- `note(run, reason, detail, cid)`: `{ t, what = reason, label, detail }` in the case's notes, the suspect's notes and
  the timeline, and `CP.AntiCheat.note(run, nil, reason, detail, cid)` (§5.26: audited as runNoted once per reason and
  suspect, so every suspect of a crew who logs off is in the audit, shown in the Review run detail, never
  `run.flagged` or `p.flagged`). Everything a suspect does himself is a note: `rs_combat_log`,
  `rs_evade_instance`, `rs_fake_arena_flag`, `rs_teleport`, `rs_went_on_duty` here (critic 2 #12).
- `sampleCrew(key, cids)` / `unsampleCrew(key, cids?)`: AFK samples for citizenids with no case yet (a crew whose
  contract started, a volunteer; C17); the same key again adds to its list, `unsampleCrew` without cids drops the key.
- Event-kept maps (critic 2 #20, LOOP_RULES 8): `srcOf[cid]` / `cidOf[src]` for tracked citizenids only, set at open,
  `sampleCrew` and `CP.Qbx.onPlayerLoaded` (getInfo once: an event path), cleared by `CP.Qbx.onPlayerUnload` and
  `playerDropped`, so a server id another player gets after a drop never matches a record (C9). `rec.md` is seeded by
  getInfo at open and at a rejoin and then kept by `CP.Qbx.onMetaDataChange(fn, { 'ishandcuffed', 'isdead',
  'inlaststand', 'injail' })` (old == new ignored). `CP.Qbx.onDutyChange` / `onJobChange` putting a suspect on duty
  in a Config.Departments job: free or cuffed -> void, and the note `rs_went_on_duty` (critic 2 #19). Another script's
  crimsonArena flag is seen by a state bag change handler (and checked at open, at a rejoin and on the way out of an
  instance): in bucket 0 it is the note `rs_fake_arena_flag` once, and he stays tracked (C8).
- The watch: one thread, `Wait(1000)`, started by the first `open` or `sampleCrew`, ended when no case and no crew is
  left (an exit token: never two copies). A pass reads each case's active participants' server coords once, and per
  suspect with a src only `GetPlayerRoutingBucket`, `GetPlayerPed` and `GetEntityCoords` (and
  `GetPlayerCameraRotation` on an AFK sample): never a Qbox export. A bucket other than 0 is leaving (critic 2 #14):
  cuffed -> detained, free -> the onLeave rule at once, detained and booked stay (C25), always the note
  `rs_evade_instance` ("contact N s ago" / "no contact"). A move faster than Config.AntiCheat.maxSpeed since the last
  pass is the note `rs_teleport` (not on the first pass after a rejoin or an instance). Contact: an active participant
  within contactRange (`contactAt` once with `opp_contact`, `lastContactAt` every pass). Lost, with `case.lostRule`
  only: a free suspect, after contact or `crimeEnded`, with no participant within `range` for `seconds`. A trail point
  every `trail.every` s, at most `trail.max` per suspect (a ring). AFK: a sample every `afkSampleEvery` s (coords and
  camera; still = moved under 1 m and turned under 2 degrees since the stillness began, AFK after `afkSeconds`), for
  free suspects who are not down and sampled crews only: the samples stop while a suspect is cuffed, detained or
  booked (C17) or down (`rec.down`, kept by the proof step: lying still waiting for EMS or the respawn timer is not
  AFK), and `rec.afk` keeps its value from the cuff or the down. Offline suspects only wait for their grace.
- Leaving: `playerDropped` and `CP.Qbx.onPlayerUnload`. A cuffed suspect is detained at the drop (C18); a character
  switch or logout is final at once; any other drop waits `disconnectGrace` s for a rejoin. When the leave is final:
  cuffed -> detained, free -> `Config.RealSuspects.onLeave` ('void' -> left, 'caught' -> detained with `byLeave` and
  share 1, or 0 when he was AFK, 'escaped' -> lost), detained and booked keep their state, and always the note
  `rs_combat_log` ("left within N s of contact" inside evadeWindow, "contact N s ago", "no contact", or "offline when
  the case opened"). Rejoin within the grace: the same record with the new src, the mirror read again; a suspect who
  left cuffed or detained and comes back within reconnectNoticeMinutes: the toast `opp.back_in_city` to the case's
  active participants (no name).
- Every state change: the timeline, and while the run is In progress `CP.Runs.dispatch(run, case.index, nil, { type =
  'opp_<state>' ('opp_released' for free), cid, label, prev, by, share, why })` (before that the state is only kept;
  the block reads `view` at its start). The opp_* types are server-only (§8.2: `server:objective` refuses them from a
  client and flags `unexpected_event`).
- Opponents are never in `run.entities`, CP.Npc's registry or a `cp` bag. Resource stop clears everything.

Proof (V5, modules/opponents/proof/server.lua; critic C10, C18, C19, C26, C28, critic 2 #5, #6, #15, #30). The server
facts that decide every detain and booking. Inputs: the `CP.ScPolice.on` facts ('cuff', 'uncuff', 'cuffBreak',
'bobbyPin', 'escort', 'jail') and `CP.Ambulance.on('respawn')` (§5.1, V3: they pass only while a case is open), the
metadata mirror through `Opp.onMeta` (ignored while the suspect is in a bucket other than 0, where Crimson-Arena
rewrites cuffs and downs) and `Opp.onTick`. Times are GetGameTimer() ms. Nothing here calls CP.AntiCheat.flag: a
suspect's own acts are `Opp.note`s.
- Cuff pair. A 'cuff' by an active participant of a run with `run.live` calls `CP.LiveCrime.cuffHint(run, src)` (when
  it exists) for every target, suspect or not (C5), after the attempt below is kept. On a free suspect the attempt is
  kept only when the officer is on duty in a turned-on department job (`CP.Qbx.getInfo` job and
  `CP.Access.departmentForJob`, never `getOfficer`: a listener must not yield, and getOfficer's suspension and retired
  lookups await the database on a cache miss, so the suspect's cuffed state could arrive first; a participant passed
  getOfficer when he joined, and a suspension ends his part in the run; sc-police checks neither job nor duty), both
  are in bucket 0, the officer is not `CP.Alerts.inArena`, and the server distance is within `cuffRange`: a
  participant's as `rec.cuff = {
  officerSrc, at }` (timeline `cuff_attempt`, `opp_cuff_attempt`), an on-duty officer outside the case's as
  `rec.outsideCuff = { src, at }`; a refused participant attempt is the timeline line `cuff_refused` (why
  not_on_duty, instance, arena, distance). `ishandcuffed` false -> true (old == new ignored: sc-police registers
  SetHandcuffStatus twice) within `cuffPairWindow` of `rec.cuff` -> `cuffed` (`cuffedAt`, `caughtBy = { officer }`)
  with `share` 0 and the note `rs_afk_catch` when `rec.afk` (critic 2 #15), `neutralisedShare` when `rec.down`
  (whoever downed him, C28) or after a C26 respawn, else 1; within the window of `rec.outsideCuff` ->
  `rec.outsideCuffed = true` and the line `cuffed_by_outsider` (V15 decides assist or stopped); no pair -> the line
  `cuffed_unproven` only.
- Hold. On the watch pass a `cuffed` suspect whose mirror still says cuffed after `custodyHoldSeconds` -> `detained`
  (`custody_hold`, by the cuffing officer), once per suspect per case (detained and booked never go back). Every
  detain is refused while `rec.protectUntil` lasts: the line `spawn_protected` and back to free. An 'escort' by an
  on-duty participant (same plausibility, `cuffRange`) of a downed suspect who is free -> `detained` (`escort_down`)
  at `neutralisedShare` (0 and `rs_afk_catch` when AFK).
- Getting free during the hold (`ishandcuffed` true -> false while `cuffed`): explained by, in this order, a
  participant's 'uncuff' within 5 s (`released`), a 'bobbyPin' success within 5 s (`rescued`, no note) from a sender
  who is not the suspect, not cuffed or down (`CP.Qbx.getInfo(sender).metadata` at the event), in bucket 0, counted
  near him on at least 2 watch passes before the result, with no earlier rescue of this suspect in the case (the
  nearest such cuffed suspect is the one he picked; critic 2 #6), or the suspect's own 'cuffBreak' within 5 s when the
  cuffs came off between 2 s and `breakFreeSeconds` after `cuffedAt` and it is his first break-free in the case
  (`broke_free`; critic 2 #30). Each of these goes back to free (`opp_released` with that why). sc-police sends its
  cuff-break alert just after the uncuffed state, so an unexplained release waits 2 s (and is decided at the close);
  anything else is a self-uncuff (sc-police /fixcuffs or an admin /resetcuffs: both a server SetMetaData with no
  event) -> `detained` (`self_uncuff`) and the note `rs_self_uncuff` ("self-uncuff or admin reset"). An 'uncuff' by
  someone outside the case (sc-police asks only for the handcuffs item) explains nothing either, but it is kept
  (bucket 0, within `cuffRange`; the line `uncuffed_by_outsider`, else `uncuff_refused`): when it came within 5 s of
  the cuffs coming off the detain is `outside_uncuff` and the note is `rs_outside_uncuff`, which names him instead of
  saying that no officer uncuffed the suspect. The suspect's uncuff of himself stays a self-uncuff.
- Rescue candidates. Only while a suspect is `cuffed` and not yet released, the pass reads the online players once
  (`CP.Qbx.getOnlinePlayers()`, the event-kept list) and their server coords, and keeps `rec.near[src]` = consecutive
  passes within `rescueRange` for players who are neither the suspect nor a participant (reset when out of range).
  With no suspect cuffed the pass reads nothing; a hold lasts at most `custodyHoldSeconds`.
- Down. `isdead` or `inlaststand` true -> `rec.down`, `downAt`, `downNear` (a participant within contactRange then),
  `opp_down`; both false -> up, `upAt`, `opp_up`.
- Booking, matched in either order (critic 2 #5: sc-police writes injail inside its own JailPlayer handler and qbx
  fires onSetMetaData at once): `rec.injailAt` = the last injail 0 -> above 0 change; a 'jail' by an on-duty
  participant within `jailRange` of a `detained` suspect -> `rec.jail = { officerSrc, t = math.floor(tonumber(jailTime)
  or 0) (C19), at, inZone }` (inZone: the officer inside one of `bookingZones`, {} = anywhere). Whichever arrives
  second pairs them within 10 s (each is used once) -> `booked` (`rec.jailTime = min(t, jailTimeMax)`) when `t >=
  minJailTime` and inZone; else the line `booking_too_short` or `booked_outside_station`, no booking. A
  participant's jail that cannot be a booking is the line `jail_refused` (why not_detained, for a jail during the
  hold, not_on_duty, instance, arena or distance; with the months): sc-police jails him all the same, and that injail
  rise can never pair later. A jail by
  someone outside the case of a free or cuffed suspect, paired the same way with the injail change -> outcome
  `stopped` (state `void`, counts for nobody) and the note `rs_outside_jail`. sc-police's prison exports are never
  called (not loaded).
- Hospital. A 'respawn' of a suspect who is not down (or got up more than 5 s before), or was down for less than
  `earlyRespawnSeconds` -> `void` (free or cuffed only) and the note `rs_early_respawn`. Otherwise
  `rec.protectUntil = now + spawnProtectSeconds` (line `spawn_protect`), unless a participant was within contactRange
  at the down and is again at the respawn (C26: no protection, `rec.hospitalCatch`, and his next cuff scores at
  `neutralisedShare`; line `respawn_in_contact`).

Conduct (V6, modules/opponents/conduct/server.lua; critic C6, C7, critic 2 #12). How officers treat a real suspect,
from server facts only. Every flag here is an officer-conduct flag: `CP.AntiCheat.flag(run, officerSrc, reason,
detail)` with the server id of the officer who fired, drove or seized, so only his points are held for review (never
his partner's, never `run.flagged`; AC.flag refuses anyone who is not a participant of the run). A supervisor's void
of his row in Review is the "Failed": nothing here ends or fails a run, and nothing cancels a game event.
- Armed (C6): `rec.armedUntil` / `rec.everArmed`. The watch pass (`Opp.onTick`) reads `GetSelectedPedWeapon(
  GetPlayerPed(src))` of every tracked suspect (not lost, left or void, not in an instance; natives only): a weapon
  that is not WEAPON_UNARMED and not in `Config.RealSuspects.lessLethal` (each name hashed once with joaat, again when
  the list or any setting changes) sets `armedUntil = now + armedMemory` and `everArmed`. The officer's hit reads his
  hand once more (he may have drawn between two passes). A suspect's hit on an active participant of his case sets
  `everArmed`, and so does `Opp.noteArmed(cid)` (Crimson-Contracts' crew shot, V10). The first time is the timeline
  line `armed` (why weapon, damage). `Opp.armedState(cid) -> armedNow, everArmed`.
- The ledger. A third read-only `weaponDamageEvent` listener (CP.Npc has two): it returns at once while
  `Opp.active()` is false (no native read), and while a case is open it reads nothing for a sender who is neither a
  suspect of a case nor an active participant of a run with a case. A hit is blamed only on its sender (a forged
  packet never costs a third party); damage from an NPC the sender simulates (a ped, or a car an NPC drives:
  `parentGlobalId`, as CP.Npc's ShooterOf reads it) is nobody's. Victims: each `hitGlobalId(s)` (at most 32)
  through `NetworkGetEntityFromNetworkId`, a player's ped when `IsPedAPlayer` is truthy (a server BOOL native), the
  victim's server id = `NetworkGetEntityOwner`; both in routing bucket 0. Only a participant -> his case's suspect
  (dir 'officer') and a suspect -> a participant of his case (dir 'suspect') go in `case.ledger`: `{ t, at, lastAt,
  dir, from, to, cid, label, weapon (unsigned hash), willKill, state, down, n, rules }`; the same sender, victim and
  weapon within 2 s adds to the last line (`n`), and at most `damageLogMax` lines are kept (the oldest go first).
- A participant's hit on his case's suspect, in this order: (1) the suspect is in custody: still restrained (CP's
  own proven `cuffed` or `detained` state AND the event-kept cuffs mirror `rec.md.ishandcuffed`; C7 forbids raw
  metadata on its own, and a `cuffed` rec whose cuffs came off, `rec.freedAt`, is not), or `detained` and down for
  more than `downGrace` s (sc-ambulance disables every control while he is down); or down (`rec.down`, kept by the
  proof step) for more than `downGrace` s with an earlier hit by the case's officers (`rec.firstHitAt` before
  `downAt`) -> flag `rs_excessive_force`, any weapon. `detained` never goes back to free: a suspect who freed himself
  (a self-uncuff), was revived after an escort while down, or was bobby-pinned after the hold is not in custody, so
  what he does then never holds an officer's points (critic 2 #12); (2) a shot (a weapon that is not less-lethal, not WEAPON_UNARMED, not a vehicle and not a fall) on a
  suspect who was never armed (`not everArmed and armedUntil < now`) -> the personal penalty `rs_unarmed_shot`
  (`CP.Runs.penalize(run, id, { src = officerSrc })`) and the flag `rs_unarmed_shot`; (3) WEAPON_RUN_OVER_BY_CAR or
  WEAPON_RAMMED_BY_CAR on a suspect on foot (`GetVehiclePedIsIn(ped, false) == 0`) -> the penalty `rs_ran_over` and
  the flag `rs_vdm` (ramming the car he flees in is never penalised). Each penalty and each flag once per officer
  per suspect; a timeline line names the officer (`by`). Config.Bonuses `rs_unarmed_shot` and `rs_ran_over` are
  engine-only pct penalties (-0.25 each, `each`): -25% of P per suspect on that officer's row.
- Cash seizures: the `CP.ScPolice.on('seizeCash')` fact (V3, only while a case is open). sc-police acts only for an
  on-duty job of type `leo`, so anyone else's event is ignored (`CP.Qbx.getInfo` job type and duty); it takes
  nothing from a target with no cash, and whether CP's handler runs before or after its own is not known, so every
  record says Seize Cash was used (an attempt). An attempt by an active participant of a run with a case, or any
  attempt on a suspect, is audited (`CP.Admin.audit(officerSrc, nil, 'flags', 'seizeCash', runId,
  'own_suspect'|'other_case'|'not_suspect', CP's state of the target, "target, server distance, CP-cuffed")`, in its
  own thread: a listener never yields; CP-cuffed is the restrained test above). One on a suspect who is not under
  arrest (`cuffed`, `detained`, or `booked`: CP's proven states, on purpose not the cuffs mirror) or from more than
  3 m away (server coords) -> the flag `rs_bad_seize` on the seizing officer when he is a participant of that case
  (his own conduct, with or without cash); an officer outside the case cannot be flagged on its run, so it is the
  staff note `rs_bad_seize` (Opp.note, naming him).

Identity and pairs (V7, modules/opponents/pairs/server.lua, table `cp_pvp_pairs` from
sql/migrations/009_real_suspects.sql; critic C27, critic 2 #21-#23, #30). The anti-farm core both features share.
Every answer below is a memory lookup (no database statement on a claim, a view or a tick); the ledger is read once at
start, and every write goes to the database in a thread.
- `selfBlock(officerSrc, suspects) -> blocked, kind, flags, match`: `suspects` is a list of citizenids or a map keyed
  by them (`{ [cid] = src }`: the server id is only a hint, checked against getInfo). In this order, per suspect: (1)
  `own_character`: one of `CP.Access.selfCitizenids(officerSrc)` (every character of his licenses, offline ones
  included); (2) `own_license`: his player's licenses (`CP.Access.licensesOfSrc` and Qbox's users row of each,
  `CP.Qbx.userLicenses`) hold the suspect's license (online: `getInfo(src).license`; offline: `CP.Qbx.licenseOf(cid)`,
  kept per citizenid), strictly: a nil or unknown license on either side refuses (`Opp.sameUserStrict(a, b)`, which
  asks `CP.Access.sameUser` otherwise; critic 2 #22); (3) both online: every identifier (`GetNumPlayerIdentifiers` /
  `GetPlayerIdentifier`, i = 0..n-1) and token (`GetNumPlayerTokens` / `GetPlayerToken`, kind `token`), compared as
  whole strings grouped by the text before ':' (never `GetPlayerIdentifierByType`, which matches by prefix): a shared
  one of a kind in `Config.RealSuspects.identityMatch.block` -> `linked_account`; of a kind in `identityMatch.flag`
  (`ip`, `token`) -> not blocked, `flags = { 'rs_linked_accounts' }` (an officer-conduct flag: the caller raises it
  with `CP.AntiCheat.flag(run, thatOfficerSrc, ...)`, V14 / V22b). `match = { cid, kinds }` names the suspect and the
  kinds only: identifiers are never stored, logged, audited or sent. Characters and licenses are read once per
  officer session (`selfCache[src]`, cleared by `CP.Qbx.onPlayerUnload`, `onPlayerLoaded` (a character switch) and
  `playerDropped`; critic 2 #21): a cache hit with online suspects runs no database statement.
- Duty maps from `CP.Qbx.onDutyChange` / `onJobChange` / `onPlayerLoaded` / `onPlayerUnload` and `playerDropped`
  (getInfo once per event; Config.Departments jobs, a turned-off department too), seeded at start from
  `getOnlinePlayers`: `Opp.dutySince(cid)` (os.time() his department duty began; the resource start for one on duty
  then or never seen going on duty), `Opp.lastPoliceAt(cid)` (he left department duty, a department job, or logged
  off on duty; V4's `eligible` reads it for `job_hop`), `Opp.lastSuspectAt(cid)` (a case with him as a suspect closed:
  the `run:ended` hook and the case rows). Each time someone leaves police duty a `duty_off` row is written (officer =
  cid, suspect ''), while Config.LiveCrime.enabled or Config.Volunteers.enabled is on, so a restart keeps the
  job-hop history (critic 2 #30); the maps themselves are always kept.
- The ledger `cp_pvp_pairs (id, kind, run_uuid, officer_citizenid, officer_license, suspect_citizenid,
  suspect_license, outcome, scored, until_at, created_at)`, kind `live` | `volunteer` (one row per officer and suspect
  of a closed case), `block` (an admin pair block), `exclude` (officer ''), `suspend` (suspect '') and `duty_off`.
  `Opp.recordPairs(run, rows)` at a case's close (V14, V22b): `rows = { { officer, suspect, scored, outcome?, kind?,
  officerLicense?, suspectLicense? } }` (kind defaults to the case's, the licenses to the participant's getInfo and
  the suspect record's); kept in memory at once, the same row twice once, written as one INSERT in a thread, created_at
  = FROM_UNIXTIME(os.time()). At start (in a thread, after the clean-up below): the case and duty_off rows of the last
  max(pairCooldownHours, 24 h, pairFlag.days, jobHopMinutes, suspectCooldownMinutes) and every admin row whose until_at
  is still ahead; a longer window set in game reads the older rows once (`settings:changed`).
- Caps: `Opp.pairOk(officerCid, suspectCid) -> ok, reason, until` (`blocked` an admin block, `pair_cooldown` a scored
  case of the pair within pairCooldownHours, `suspect_cooldown` any case of the pair within suspectCooldownMinutes;
  rows with outcome `gone`, nobody reached the suspects, never count), `Opp.suspectDayCount(cid)` (cases since today's
  reset, `CP.Schedule.dayStart`, in which he scored for someone: maxCatchesPerSuspectDay), `Opp.officerDayCount(cid,
  kind?)` (his cases today, `gone` left out), `Opp.excluded(cid)`, `Opp.suspended(officerCid)` (-> bool, until), and
  the admin writers for V17 `Opp.block(officerCid, suspectCid, days)`, `Opp.exclude(cid, days)`, `Opp.suspend(
  officerCid, days)` (-> true, until | false, 'invalid_citizenid' | 'invalid_days'; 0 < days <= 3650).
- Pair repeat (C27): `Opp.checkPairFlags(run)` after recordPairs, for each officer and suspect of the run: the cases of
  that pair (matched by license, else citizenid) within pairFlag.days reach pairFlag.count AND a second sign exists (a
  detain within fastCatchSeconds of `case.openedMs`, a suspect never armed who got less than 30 m from where contact
  was made, `rec.movedAfterContact` kept by an `Opp.onTick` listener while he is free, or a case shorter than 180 s)
  -> `CP.AntiCheat.flag(run, thatOfficerSrc, 'rs_pair_repeat', detail)` (personal, once per officer and run) and a
  `pair_repeat` timeline line; returns the flagged officers' citizenids.
- Retention (critic 2 #23, LOOP_RULES 11): once at start and on every `CP.Schedule.onDaily`, in a thread: `DELETE`
  the `live`, `volunteer` and `duty_off` rows older than pairLedgerDays (one statement per kind) and the admin rows
  whose until_at has passed; never in a tick.

### 5.46 CP.LiveCrime — modules/livecrime and modules/integrations/crimson_contracts (S)

Option A, live crimes (Config.LiveCrime, `enabled` shipped false). The adapter in modules/integrations/crimson_contracts
listens to Crimson-Contracts' server-only lifecycle events (crimson-contracts:server:*, AddEventHandler only, from the
scripts in Config.LiveCrime.sources) and never requires that resource; CP.LiveCrime turns a contract whose police
alert went out into a red LIVE call on the Dispatch screen, opens a CP.Opponents case for the crew when a unit claims
it (no draw: the engine-only `live_crime` mission with the `live_response` block, §7.3), lets backup join the case,
scores it with the live_* lines (points only unless the owner turns on its money switches), and reports the result to
other scripts with the read-only export GetAvailablePolice and a server-only end event. Built in steps V4-V26
(/tmp/claude-0/-home-user-PoliceTablet/c9b2f5e1-32ec-5436-a1db-2a78c5b9aa69/scratchpad/pvp/DESIGN_FINAL.md).

**Intake (V10).** Crimson-Contracts sends its events only with `ContractsConfig.LifecycleEvents = true` (shipped false);
names and payloads as built in its step VC3 (commit e20316f, its README "Integration"):

| Event | Payload (Crimson-Contracts) | CP.LiveCrime |
|---|---|---|
| `crimson-contracts:server:contractStarted` | `{ id, uid = '<id>_<start time>', key, label, locationLabel, coords = { x, y, z }, members = { [citizenid] = server id }, leaderCitizenId, startedAt, test }` | `onStarted` |
| `crimson-contracts:server:dispatchSent` | `{ id, uid, dispatchId = 'crimson_contract_<id>_<time>', title, street, coords }` (never for ATM alerts) | `onAlert` |
| `crimson-contracts:server:contractEnded` | `{ id, uid, outcome = 'completed'\|'failed'\|'cancelled', reason }` (also for a contract that never started) | `onEnded` |
| `crimson-contracts:server:memberRejoined` | `{ id, uid, citizenid, src }` | `onRejoined` |
| `crimson-contracts:server:crewShot` | `{ id, uid, citizenid, suppressed, trigger = 'shot'\|'gun_kill' }` | `onCrewShot` |

- **Adapter (CP.CrimsonContracts, `CC.EVENTS`).** The five handlers are registered always (C29: turning `enabled` on
  in Admin UI → Settings needs no restart) and return at once while `Config.LiveCrime.enabled ~= true`. Then:
  `GetInvokingResource()` must be in `Config.LiveCrime.sources` (read on each event; any other script, or none, is
  dropped with one CP.warn per minute per script that names the setting); the payload must be a table of the shapes
  above: `id` a whole number, `uid` a name (letters, digits, `_`, `-`) of at most 32, `key` and `outcome` / `trigger`
  names of at most 64 / 16, `citizenid` / member keys names of at most 50 and at most 16 members (at least one),
  `coords` a table of three finite numbers, `test` / `suppressed` booleans or nil, `dispatchId` a name of at most 64
  or nil; `label`, `locationLabel`, `title`, `street`, `reason` must be strings and are trimmed, freed of control
  characters and cut to 64 / 64 / 50 / 100 / 128 bytes. Anything else drops the event (one warning per minute per
  script and event). **Every server id in a payload is ignored (C9):** `members` keeps only its keys and
  memberRejoined's `src` is never read. The clean copy goes to `CP.LiveCrime.<fn>(resource, data)` inside pcall.
- **Records.** `crimes['<resource>:<uid>'] = { crimeKey, res, uid, id, key, label, locationLabel, coords, members = {
  [cid] = true }, leader, startedAt, receivedAt, test, sampled, alertedAt, dispatchId, title, street, missionType,
  suspects = { [cid] = true }, armed = { [cid] = os.time() }, ignored, ended, endedAt, outcome, endReason, runId }`, in
  memory only: at most 200 at once, pruned on the next event 1 h after the end (or 2 h after the start when no end
  ever came); a reporting resource that stops ends its open crimes (`outcome = 'stopped'`). No timer or thread.
- `onStarted`: a known uid is ignored; `test == true` (an admin's `/testcriminalcontract`, C16) is kept as a test
  record, audited `liveCrimeIgnored` (new value `test`) and never sampled or reported. Otherwise, while its key maps to
  a mission type, `CP.Opponents.sampleCrew(crimeKey, cids)` starts the crew's AFK samples at the contract start (C17).
- `onAlert` (once per crime): an unknown, test or ended crime, or an id that does not match, is ignored. The key maps
  through `Config.LiveCrime.types` (a Config.MissionTypes key; false, missing or an unknown type = off: audit
  `liveCrimeIgnored`, `type_off`). Each member is found with `CP.Qbx.getByCitizenId(cid)` (an event path) and his
  `getInfo` citizenid must match; he is a suspect when `CP.Opponents.eligible(src, { intake = true })` passes and his
  server coords are within `Config.LiveCrime.suspectRadius` (300 m, C24) of the crime. None -> audit
  `liveCrimeIgnored` (`no_suspect`, the reasons counted) and the samples stop. Else `suspects`, `alertedAt`,
  `dispatchId`, `title`, `street`, `missionType` are stored, the members who are not suspects stop being sampled, the
  audit `liveCrimeReported` (new value `<suspects>/<crew>`, the reasons for the others) is written and
  `CP.LiveCrime.post(crime)` is called (V10: it only logs "would post"; V11 posts the LIVE call). Audit lines are
  category `audit`, actor console, target the crime key, written in their own thread; they carry no citizenid.
- `onEnded`: `ended`, `endedAt`, `outcome`, `endReason`; the open run of `crime.runId` (V14 sets it; its
  `run.live.crimeKey` must match) gets `CP.Opponents.crimeEnded(run)`; the samples stop.
- `onRejoined`: a member of a crime whose case runs gets a `crew_rejoined` timeline line (CP.Opponents re-resolves him
  on the qbx load event itself, V4).
- `onCrewShot` (C6): `crime.armed[cid] = os.time()` for a member, and `CP.Opponents.noteArmed(cid)` when he is a
  suspect of the crime's running case. V14 copies `crime.armed` into the case when it opens. Crimson-Contracts sends
  at most one `'shot'` per contract (the report that made its police roll; later reports are not checked there) and
  one `'gun_kill'` per guard shot dead by a crew member, so a crew member who only fired after that roll is not
  reported: CP.Opponents' own weapon sample and damage ledger (V6) decide whether he is armed in the case.
- API: `LC.get(crimeKey)`, `LC.crimeOf(run)` (`run.live.crimeKey`), `LC.inCrew(cid) -> bool, crime` (a member of a
  crime that has not ended; always false while `enabled` is off and for test crimes; V22 uses it), `LC.post(crime)`.
- Config.LiveCrime keys of V10: `sources = { 'crimson-contracts' }` (a list of resource names), `types` (an OPEN table
  in Settings: Crimson-Contracts' contract keys -> a Config.MissionTypes key or false, checked by Settings),
  `suspectRadius = 300.0` (10-2000 m).

### 5.47 CP.Volunteers — modules/volunteers (server, client; stub)

Options B and C, volunteer suspects (Config.Volunteers, `enabled` shipped false). A player who is not on police duty
volunteers with the command in Config.Volunteers.command for an hour and only ever sees ox_lib notifications, dialogs
and a context menu (no tablet). A mode per mission type or mission ('npc', 'players_when_available', 'players_only')
decides whether a mission whose block offers a volunteer slot (§7.3) is played against a volunteer who said yes to the
pop-up instead of the NPC; 'players_only' is offered only while a volunteer who fits is online. Every mode ships
'npc', so nothing changes even with `enabled = true`. Built in steps V4-V26
(/tmp/claude-0/-home-user-PoliceTablet/c9b2f5e1-32ec-5436-a1db-2a78c5b9aa69/scratchpad/pvp/DESIGN_FINAL.md).

## 6. Cross-cutting conventions

### 6.1 Entities and NPCs
- Server spawns with OneSync server natives: `CreatePed(4, model, x, y, z, heading, true, true)`,
  `CreateVehicle(model, x, y, z, heading, true, true)` (or `CreateVehicleServerSetter` for correct
  vehicle type), `CreateObjectNoOffset(model, x, y, z, true, true, false)`. Wait until
  `DoesEntityExist`, then `NetworkGetNetworkIdFromEntity`. Then (Config.Spawning.place) the entity is frozen
  (`FreezeEntityPosition`, a server RPC) and its first cp bag asks an officer's game to put it on the ground (§5.43). `SetEntityOrphanMode(entity, 2)` is not used
  (the engine deletes everything itself). Weapons: `GiveWeaponToPed(ped, hash, CP.NpcCombat.ammo(), false, true)`
  with the weapon `CP.NpcCombat.weapon` gives (§5.42); armour: `SetPedArmour(ped, n)` (server natives).
- Yes/no natives: on the server a native that answers yes or no (`DoesEntityExist`, `IsPlayerAceAllowed`,
  `SaveResourceFile`, `IsPedAPlayer`, `IsDuplicityVersion`...) gives Lua the integer 1 for yes and false for no,
  never true (`_r` in FXServer's natives_server.lua). Read the answer as a condition (`if DoesEntityExist(e)`)
  or accept both (`v == true or v == 1`), never `== true`; a value that leaves the function (a table field, an
  event, the NUI) is turned into a real true or false first. Client natives give true or false (the manifest's
  `use_experimental_fxv2_oal`), and client code accepts both anyway. `tests/harness.lua` gives every server mock
  of such a native FXServer's answer, so a spec catches a `== true`.
- Anything that only exists client-side (accuracy, health above 200, combat attributes, drop-weapons,
  relationship group, tasks) is applied by the **host** client from the `cp` state bag with
  `CP.Npc.apply` after it has control. When the host changes, the new host re-applies and re-tasks. The
  Config.NpcCombat caps are applied by whichever participant's game owns the ped (the combat governor, §5.11).
- Relationship groups (client, host): `CRIMSONPOLICE_HOSTILE` hates `PLAYER` (5), is neutral to everything
  else; `CRIMSONPOLICE_NEUTRAL` (hostages, witnesses, racers, fugitives) is neutral to all. Only the
  relations *from* these two groups are set; `PLAYER`'s own relations are never changed (§0.14).
- Dead NPCs and wrecked vehicles are deleted `Config.Limits.corpseCleanup` s after death by the engine.
- Caps (`maxArmedAlive`, `maxEntities`) are checked *at the moment of spawning*: a wave that does not fit
  waits (re-checked each tick) and its counts are never reduced.

### 6.2 NPC state (the `cp` state bag, server-authoritative)
`Entity(e).state.cp = { run, obj, role, state, armed, cfg = { weapon, accuracy, armour, health, behaviour, model } , tag }`,
plus `gait` (`'sprint'|'jog'|'walk'|'spent'`, CP.Npc's flee clock, §5.11; missing = sprint; the game that owns a
fleeing ped holds it to that pace, §5.11 client), and `place = { x, y, z, h?, kind = 'ped'|'vehicle'|'object', token,
from? }` on any mission entity (people, vehicles, objects): the server's ask that a participant's game put it on the
ground at x, y (Config.Spawning.place; the placer, §5.43, answers `server:spawnPlaced` once per token; `from = { x, y
}` where it waits after the server moved the ask to another point). The server writes it with the entity's first bag
and keeps it in its record copy, so later writes of the bag carry it, until it takes an answer or gives up waiting: it
removes `place` from the bag in both cases (`CP.Npc.setPlace`), since while the bag carries one CP.Npc never lets the
entity go, `CP.Spawn.holds`.
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
- Signed manual rows (full admin control): an adjustment is `mission_type = 'manual_award'` with `mission_id =
  'manual_award'` (positive points) or `'manual_adjust'` (negative points); `breakdown.by` names the admin and
  `breakdown.reason` the reason. Boards and the challenge sum the signed points; run counts, goals, streaks and the
  draw leave both out (`mission_type NOT IN ('manual_award', 'goal')`). XP is `max(0, signed sum)` of the counted
  rows; flag by hand and supervisor review refuse `manual_award` and `goal` rows, so a deduction is undone only by
  voiding it.
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

Admin transitions (full admin control, §5.20, §5.40; the money ones ship off behind `Config.Cash.allow*`):
`paying` → `paid`/`capped` (Mark paid, no money; or Pay again, txn `-r2`, read from the step markers `claimed` →
`withdrawn` → `added`); `unfunded` → `pending` → paid (Retry unfunded, same txn); `capped` stays `capped` with
`cash_paid` + the rest (Pay the rest, txn `-r`, marker `restPaid`); `forfeited` (with `cash_paid = 0`, not voided) →
`pending` → paid (Pay it after all); `held`/`pending` → `forfeited` (Forfeit now on a voided row with no open dispute;
Cancel payment on any); `paid`/`capped` keep their status while `cash_reclaimed` grows (Take back, txn `-back<n>`).
A manual cash payment (`manual_award` / `manual_cash`) starts `pending` and follows the normal flow outside the cap.

---

## 7. Objective block interface

### 7.1 Server half — `blocks/<id>/server.lua`

```lua
CP.Blocks.register('hostile_waves', {
  defaults = function(obj) return obj end,                 -- fill block defaults (§3.3) in place, return obj
  validate = function(obj, mission, location) return true end,  -- or false, 'reason' (loader + builder guardrails)
  armedCount = function(obj) return 20 end,                -- armed NPCs before scaling (40 budget)
  requiredPoints = function(obj) return { 'spawns' } end,  -- location keys the builder must place
  pointKinds = function(obj) return { { key = 'spawns', kind = 'ped' } } end,
                                   -- (optional) what is at each location key it uses, for the spawn point check
                                   -- (§5.27): kind 'ped' | 'vehicle' | 'prop' (where they appear), 'marker' (where
                                   -- officers stand) or 'path' (where they drive or run); first = the kind of the
                                   -- key's point 1 (the escort truck at route[1]); model = a vehicle's model
  prepare = function(ctx) end,     -- the run moved to In progress (called for EVERY objective, in order)
                                   -- state only: a block places its people in start or stage (PLAN S15); the
                                   -- engine warns once per block whose prepare made entities anyway
  spawnsInPrepare = function(ctx) return false end,
                                   -- (optional) true = this prepare makes entities on purpose (an owner setting
                                   -- asked for it: protect_rescue with Config.Spawning.hostagesAt = 'runStart'), so
                                   -- the engine does not warn
  start   = function(ctx) end,     -- this objective became current
  tick    = function(ctx, dt) end, -- every 1 s while current (dt seconds); check fail/complete conditions here
  onEvent = function(ctx, src, ev) return true end,       -- client evidence for this objective; return false,'reason' to reject
  onEntityDead = function(ctx, netId, killerSrc) end,     -- a ped/vehicle of this objective died
  onParticipantLeft = function(ctx, src) end,
  rescale = function(ctx) end,     -- ctx.obj now holds the counts for the smaller team: spawn only what is missing later
  onTimeout = function(ctx) return nil end,               -- return 'completed' to complete instead of failing (Street Race Bust)
  presence = function(ctx, src, coords) return distance end, -- metres from this objective's reference point (0 = inside)
  stage   = function(ctx, dt) return false end,  -- (optional) every 1 s while the objective BEFORE this one is current
                                   -- (Config.Spawning.stageAhead): place this objective's people ahead of time with
                                   -- ctx.spawnPed etc. (they are this objective's); return true once it placed them
                                   -- (ctx.staged = true from then on, its start included). Never called once this
                                   -- objective started; keep what start needs in ctx.state (the same table). It may
                                   -- yield (ctx.spawnPed waits for its entity): the engine holds this objective's
                                   -- start until it returns (at most 30 s)
  checklist = function(ctx) return { { label = 'Hostiles', done = false, value = 3, max = 20 } } end,
  marker  = function(ctx) return nil end,  -- (optional) this objective's pointer on the officers' map (§5.44 shape,
                                   -- CP.Runs.marker §5.10): asked at its start and every 1 s tick, so keep it cheap
                                   -- (server positions, no waits); name each target by the key the client half
                                   -- hands its own blip over with (CP.Markers.adopt). false = none right now (e.g.
                                   -- nothing left to do); route = 'block' = the block keeps its own GPS line
                                   -- (checkpoint_route); nil = the engine's pin at the anchor
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
  radioSilence = <bool>,               -- the run has the Radio Silence modifier (as the client half's ctx.radioSilence)
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
  choosePoints = function(candidates, n, opts) end,  -- the spawn director (§5.10): -> points, indexes, spare; opts.obj = i
  whenNear = function(point, range) end,               -- -> true once a participant is within range (activateRange)
  staged = false,                      -- true once this objective's stage hook placed its people (Config.Spawning.stageAhead)
}
```

In `stage` the objective is not current yet: `ctx.complete` is refused (it is not `run.objectiveIndex`), the HUD and
the checklist are the current objective's, and no participant's client half of this objective has started. Use
`ctx.choosePoints` / `ctx.whenNear` and `ctx.canSpawn` there like in `start`; the director's wave clocks are this
objective's own (`run.spawning[i]`). `stage` may yield: every `ctx.spawnPed` / `spawnVehicle` / `spawnObject` waits
(`Wait(0)`) until its entity exists, and the objective before can complete meanwhile from an officer's event. The
engine holds this objective's `start` until `stage` returns (at most `TICK_STUCK_MS`, 30 s), so `start` sees
`ctx.staged` and everything `stage` placed in `ctx.state`, and nothing is placed after `start`. A `stage` that is
still running after that hold returns into an objective that already started: the engine does not mark it staged
(one `CP.warn`), so write `stage` to place a wave and return, never to wait for officers.

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
- Radio Silence (`ctx.radioSilence`): after the start a client half draws a blip or a line only when
  `CP.Markers.hidden(ctx, kind)` says it may (`Config.Markers.radioSilence`, §5.44); the HUD and server halves are
  unchanged.
- Every block reads its builder ranges from `Config.Blocks[<id>]` for validation.
- A block's `update` reaches its client half while its objective is still pending too (a staged objective, §3.3): a
  client half acts on it before `start` only when its server half says so (`hostile_waves`: `awake = true`, a staged
  crew that woke before the breach), and never writes the HUD line or sends evidence for an objective that is not
  current.

### 7.3 The `live_response` block and the `volunteerSlot` hook (stub)

`blocks/live_response` is engine-only: the mission loader and the Mission Builder refuse it in a mission file or a
draft, and only CP.LiveCrime's engine mission `live_crime` (§5.46) uses it. It has three phases (Respond, Secure the
scene, Detain and book the suspects), never changes its HUD or checklist because of one suspect's state, scores from
CP.Opponents' server-only facts, and shows "last reported" points instead of live positions. `volunteerSlot(obj,
mission, location) -> { role, meet = vec3, ... } | nil` is an optional server-half function a block may add to
`CP.Blocks.register`: flee_arrest (the runner at the door), pursuit (the getaway or race driver) and search_area (the
fugitive) offer one, and CP.Volunteers (§5.47) uses it to find the objective a volunteer can play. Built in steps
V4-V26 (/tmp/claude-0/-home-user-PoliceTablet/c9b2f5e1-32ec-5436-a1db-2a78c5b9aa69/scratchpad/pvp/DESIGN_FINAL.md).

---

## 8. Net events, callbacks and actions (complete list)

### 8.1 Server → client events (`crimson-police:client:*`)

| Event | Args | Sent by |
|---|---|---|
| `client:start` | runId, data `{ missionId, mission, locationIndex, location, start = { coords, radius }, expectedTier, seed, host, test, modifier, modifiers (every twist; modifier = the first), participants, startRoute = bool, startTimeout, isBoss, npcCombat = false only when the participants' games start no CP.NpcCombat (§5.42) }` (seed = a client seed, the same for every participant and unrelated to `run.seed`, so no client can replay the server's rolls) | runs |
| `client:inProgress` | runId, `{ tier, payTier, objectives = <scaled list>, timeLimit, remaining }` | runs |
| `client:objective` | runId, index, `{ action = 'prepare'|'start'|'update'|'stop', data, marker }` (`marker` with `start`: the objective's pointer, §5.44) | runs |
| `client:hud` | runId, patch | runs |
| `client:marker` | runId, index, marker (§5.44: the current objective's pointer, new positions or a new shape; ignored unless index is the current, started objective of this run) | runs |
| `client:tierChanged` | runId, tierName, payTierName | runs |
| `client:hostChanged` | runId, hostSrc | runs |
| `client:participants` | runId, list `{ src, name, callsign, departmentShort, status, arrived }` | runs |
| `client:runEnded` | runId, result, endReason, breakdown (RunResult §9.6) | runs |
| `client:npcCombatDrop` | runId (headshot and defense protection off for the rest of that run, §5.42; ignored for any other run) | npccombat |
| `client:routeWarning` | runId, secondsLeft or nil | route |
| `client:routeRecalc` | runId, ok, recalcsLeft | route |
| `client:routeStatus` | runId, status (`'arrived'`; `'action'` once for a late partner, PLAN M11: CP.Runs then calls `CP.Route.follow`) | route, runs |
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
| `client:readyCheck` | `{ typeKey, typeLabel, expiresIn, leaderName, twists = { { key, label } } }` or nil to clear | units |
| `client:contactAct` | `{ runId, netId, behaviour, args, seconds }` to the run host only, when the behaviour starts | custody |
| `client:contactConfirm` | `{ netId, choice, factKey }`: open the tablet with the case-fail confirm | custody |
| `client:serviceVehicle` | `{ runId, id, op = 'drive'|'load'|'leave', kind, veh, driver, dest, target, away }` to the driving client | custody |
| `client:serviceBlip` | `{ runId, id, kind = 'prisonerVan'|'towTruck', show, netId, coords }` to every active participant when a transport van's or tow truck's status changes (show while coming, parked or loading), and to a late partner at `run:arrived` (§5.44 `service`, Config.Markers.serviceVehicles) | custody |
| `client:closeTablet` | errKey (requireItem: the item left the inventory) | tablet |
| `client:settings` | `{ { path, value } \| { path, none = true } }`: every setting changed in game that is in use | settings |

Server → client ox_lib callback: `crimson-police:client:roadPoint` `{ near, min, max }` → `{ coords, heading }` or nil (the service-vehicle driver's client; the server validates the reply; custody).

Server → client ox_lib callback: `crimson-police:client:spawn:visible` `{ points = { { x, y, z } } (at most 32), ms }` → `{ boolean }`, one per point, true = this game sees it (or cannot tell), false = hidden (the spawn director's hidden-first ask, `Config.Spawning.preferHidden`, §5.10; anything but `false` counts as seen; spawn).

Server → client ox_lib callback: `crimson-police:client:spawn:walkIn` `{ car = { x, y, z }, ring = { nearest, furthest }, ms }` → `{ { x, y, z, hidden } }` (at most 8, best first; empty = none fits): footpath points for a returning driver or a thief, in front of this officer, out of his sight first (`Config.Spawning.contactRing`, field_contact §3.3; the server re-checks every point and uses the ring round the car without a usable one; spawn).

### 8.2 Client → server events (spec names; payload then optional reqId)

| Event | Payload | Owner |
|---|---|---|
| `server:acceptType` | missionType (`'weekly_boss'` for the boss card), or `{ missionType, twists = { key, ... } }` → `{ runId, twists }` | draw |
| `server:unitInvite` | targetSrc | units |
| `server:unitRespond` | `{ accepted, unitId }` (a bare boolean = latest invite) | units |
| `server:unitLeave` | — | units |
| `server:joinOperation` | operationId | operations |
| `server:routeStatus` | runId, metres, coords (three args, no reqId) | route |
| `server:recalcRoute` | runId | route |
| `server:objective` | runId, index, evidence (three args, no reqId; the server-only types of §5.10, CP.Opponents' opp_* types among them, are refused and flag the sender) | runs |
| `server:telemetry` | runId, kind, data (three args, no reqId) | runs |
| `server:abandon` | runId | runs |
| `server:dispute` | `{ rowId, reason }` | disputes |
| `server:setHideName` | boolean | leaderboard |
| `server:logoFailed` | deptKey | tablet |
| `server:testRespond` | `{ inviteId, accepted }` | testing |
| `server:pickupDone` | runId, ok (plain event, no reqId) | downed |
| `server:spawnPlaced` | runId, `{ netId, token, result = 'placed'\|'bad', reason, groundZ?, dz?, z? }` (plain event, no reqId; the placer, §5.43, once per `place` token; modules/spawn/server.lua takes it from an active participant of that run for the ask's current token, at most 30 a second per player) | spawn |
| `server:spawnChecking` | runId, `{ netId, token, done? }` (plain event, no reqId; the placer, §5.43, once per `place` token before it waits for its turn, and once more with `done = true` when it gives up with no answer; modules/spawn/server.lua takes the first one from an active participant of that run for the ask's current token: the ask's time waits for that game's answer, at most 34 s + collisionTimeoutMs + interiorTimeoutMs, and runs on again at that game's `done = true`; at most 30 a second per player) | spawn |
| `server:npcCuff` | runId, netId (plain event, no reqId) | npc |
| `server:custody` | runId, netId, action, phase ('begin'\|'finish'), extra (`{ offence }`, `{ door }`) (plain event, no reqId; 4 per 2 s) | custody |
| `server:stunHit` | netId (plain event, no reqId; 2 per s) | custody |
| `server:tabletItemGone` | — (plain event; 2 per s) | tablet |
| `server:mcWatch` | false = the tablet closed (plain event) | missioncalls |
| `server:claimMissionCall` | `{ callId, twists? }` → `{ runId }` or `{ pending }` (the twists are checked before the claim joins the window) | missioncalls |
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

Other resources' net events Crimson-Police also handles, each with a second, read-only handler that never triggers,
cancels or answers them (§5.1): `police:server:Impound` (CP.ScPolice.onImpound); `police:server:CuffPlayer`,
`police:server:UncuffPlayer`, `police:server:CuffBreakAlert`, `police:server:EscortPlayer`, `police:server:JailPlayer`,
`police:server:BobbyPinResult` and `police:server:SeizeCash` (CP.ScPolice.on listeners, real suspects V3);
`hospital:server:RespawnAtHospital` (CP.Ambulance.on listeners, V3). The V3 handlers do nothing while no case with a
real suspect is open; their consumers are the proof step (§5.45, V5) and the conduct step (§5.45, V6: 'seizeCash'),
which add no event of their own. The conduct step also adds a third read-only `weaponDamageEvent` game-event listener
(CP.Npc has two): it never cancels the event and returns at once while no case is open.

Other resources' server-only events Crimson-Police listens to with `AddEventHandler` (never `RegisterNetEvent`, so no
client can send them), checked against `GetInvokingResource()`: Crimson-Contracts' `crimson-contracts:server:contractStarted`,
`:dispatchSent`, `:contractEnded`, `:memberRejoined` and `:crewShot` (modules/integrations/crimson_contracts, live
crimes V10, §5.46). Registered always; they do nothing while `Config.LiveCrime.enabled` is not true or the sender is
not in `Config.LiveCrime.sources`.

### 8.3 Supervisor, admin, builder and test actions (`CP.Net.action`) and callbacks (`CP.Net.callback`)

Callbacks (read): `getSession`, `getMissionTypes`, `getUnit`, `getRun`, `getHome`, `getBoard`,
`getProfile`, `getChallenge`, `getDeptContributors`, `getMissionList`, `getMissionDefs`,
`sup:getOperation`, `sup:getLiveRuns`, `sup:getReviewQueue`, `sup:getPayouts`, `sup:getDeptReport`,
`sup:getOfficerActivity`, `admin:getPayouts`, `admin:getMissions`, `admin:getSeasons`,
`admin:getBoards`, `admin:getStuckPayments`, `admin:searchOfficers`, `admin:getOfficer`,
`admin:getDepartments`, `admin:getPermissions`, `admin:getAudit`, `admin:exportAudit`,
`admin:getTests`, `admin:getFlagged`, `admin:getDisputes`, `builder:list`, `builder:get`,
`builder:config`, `test:pendingInvites`, `test:state` (testRun or builderEdit), `test:candidates` (testRun),
`server:test:spawnPoints` (testRun; the spawn point check and its "Teleport here" with `point`, §5.27).
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
| `server:test:spawnCheckReport` | `{ missionId, location, results = { { id, status, groundZ?, dz?, roofZ?, seen? } } }` (the spawn point check, §5.27) | testRun | testing |
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
| `server:admin:setSettings` | `{ changes = { { path, value? \| json?, none? } }, confirm?, reason? }` → SettingsReply (several settings as one save) | openAdmin | settings |

`server:admin:setSetting` also takes `confirm` (`ENABLE` for a money switch) and `reason`.


Key mappings: `crimsonpolice_dispatch` (Config.Tablet.dispatchKey), `crimsonpolice_ready` (readyKey),
`crimsonpolice_contact` (contactKey), `+crimsonpolice_testpanel` (Config.Testing.panelKey, F7). ox_target option
names (all `crimson-police:*`): `desk`, `contact_<action>`, `seat_<action>_<door>`, `custody_escort`, `body_tag`,
`body_bag`, `coroner`.

### 8.4 Admin control actions

Every action of full admin control goes through `CP.AdminKit.action` (§5.37) and needs one of the admin-only keys of
§5.3. One subsection per package; each lists its actions and callbacks with payload, permission key and guards.

#### 8.4.1 Officers, points and boards

| Name | Kind | Key | Payload / args | Guards and notes |
|---|---|---|---|---|
| `admin:getOfficerRuns` | callback | officerRecords | `{ citizenid, page, size ≤ 50, from, to, type, state, flagged, voided, kind, includeArchive }` | live + archive, the union inside a derived table for ORDER BY / LIMIT; 1/s |
| `admin:getRun` | callback | officerRecords | `{ rowId, archived? }` | debrief, participants (both tables), dispute, goal rewards it completed, `txnId`, `own` |
| `admin:getOfficerPoints` | callback | officerRecords | `{ citizenid }` | week/month/season/all-time points and ranks, `adjust.maxDeduction`, `confirmAbove`, `dailyLimit` |
| `server:admin:adjustPoints` | action | pointsAdjust | `{ citizenid, points (−10,000..10,000, not 0), reason, confirm?, requestId }` | R I S(strict) L(1 per 10 s per officer); T = the citizenid at ≥ `adjustConfirmAbove`; a deduction never takes season points or XP below 0; `adjustDailyLimit` summed from today's rows of every character of the admin's licenses (license: and license2:); audit `manualAward` / `pointsAdjust` (flags) |
| `admin:previewBulkVoid` | callback | bulkVoid | `{ filter = { citizenid?, department?, missionType?, missionId?, operationId?, from, to \| allTime, includeAwards? } }` | V: rows, officers (XP before/after), points, held cash, archived, left-out own runs, `confirmWord`, `previewToken` (none above `bulkMaxRows`) |
| `server:admin:bulkVoid` | action | bulkVoid | `{ filter, kind?, reason, confirm = 'VOID <n>', previewToken, requestId }` | R I V T J; refused while the officer is on a run; audit `bulkVoid` (flags) + one `voidRun` per row |
| `server:admin:resetProgression` | action | bulkVoid | `{ citizenid, reason, confirm = citizenid, previewToken, requestId }` | every row, all time, as a correction batch |
| `server:admin:restoreBatch` | action | bulkVoid | `{ batchId, reason, requestId }` | J; once per batch (`err.batch_restored`); un-forfeits batch-caused forfeits once |
| `admin:getCorrections` | callback | bulkVoid | `{ citizenid? }` | every batch (bulk void, retire, restore, record move, season reopen, re-check) with its Undo |
| `admin:previewRetire` / `server:admin:retireOfficer` | callback / action | officerRecords | `{ citizenid, reason, confirm = citizenid, previewToken, requestId, excludeFromBoards?, suspendDays? }` | refused on a run, in a ready check or on an operation; K on `retired_at IS NULL` |
| `server:admin:unretireOfficer` | action | officerRecords | `{ citizenid, reason, requestId }` | restores the retire batch, lifts what retire set |
| `admin:checkXp` / `server:admin:fixXp` | callback / action | progression | `{ citizenid, reason }` | writes only what the rows give; refused during a job |
| `server:admin:restoreRun` | action | restoreRun | `{ rowId, archived?, liftSuspension?, reason }` | S K (`voided = 1`); the approved-dispute path; forfeited cash stays forfeited |
| `server:admin:setVoidKind` | action | restoreRun | `{ rowId, kind = 'strike'\|'correction', liftSuspension?, reason }` | K on the old kind |
| `server:admin:flagRow` | action | restoreRun | `{ rowId, reason }` | K (`flagged = 0 AND voided = 0`); refuses `manual_award` and `goal` rows |
| `server:admin:voidRun` | action (old) | voidAnyRun | `{ rowId \| runUuid, reason, kind?, confirm?, goalRowIds? }` | gains `kind`, `VOID <n>` for a run of 3 or more, the goal rewards it completed |
| `server:admin:approveRun` | action | reviewFlagged | `{ runUuid, reason }` | every flagged row of one run |
| `admin:getBadgeCatalog`, `server:admin:grantBadge`, `revokeBadge`, `clearBadgeOverride` | callback / actions | progression | `{ citizenid, badgeId, reason }` | ids from `Scoring.validBadgeId` (an achievement, a closed week, an existing season); audit category `board` |
| `server:admin:recheckBadges` / `recheckAllBadges` | action | progression | `{ citizenid }` / `{ requestId }` | everyone: a J job |
| `server:admin:recalcStreak`, `forgiveStreakDays` | action | progression | `{ citizenid, days?, reason }` | forgive: 1..`streakForgiveMax`, once per officer per day (from `cp_audit`) |
| `server:admin:resetFirstRun` | action | progression | `{ citizenid, reason }` | online; once per officer per day (from `cp_audit`) |
| `admin:getOfficerGoals` / `server:admin:completeGoal` | callback / action | progression | `{ citizenid, kind, goalId, reason }` | the officer's current goal, not yet rewarded in the period |
| `server:admin:setBoardExcluded` | action | officerRecords | `{ citizenid, excluded, reason }` | K; self allowed (a staff test character) |
| `server:admin:refreshOfficer` | action | officerRecords | `{ citizenid }` | online; 1 per 10 s per officer |
| `admin:previewRecordMove` / `server:admin:moveRecord` / `undoRecordMove` | callback / actions | recordMove | `{ from, to, reason, confirm, previewToken, requestId }` / `{ jobId, reason }` | `AdminControl.recordMove`; T = the new citizenid or `UNVERIFIED <cid>` |
| `server:admin:postNotice` / `removeNotice` | action | officerRecords | `{ text, departments?, expiresAt, reason }` / `{ id, reason }` | 1 per 60 s per admin; ≤ 5 running |
| `admin:getOfficerLook`, `server:admin:resetLook`, `clearProfileCooldown` | callback / actions | officerRecords | `{ citizenid, reason }` | modules/profile; cooldown clear 1 per 60 s per officer |
| `admin:getBannedWords`, `admin:testBannedWords`, `server:admin:setBannedWords` | callbacks / action | officerRecords | `{ add, remove, reason }` | ≤ 5000 words, ≤ 64 characters; old file kept as `.bak`; live reload |
| `server:admin:unrevokeCommendation`, `editCitation` | action | officerRecords | `{ id, reason, citation? }` | K on the old value |
| `admin:getRecognition`, `admin:previewRecount`, `server:admin:recountWeek`, `repostWeek` | callbacks / actions | boardsAdmin | `{ weekKey, post?, reason, confirm = 'RECOUNT', previewToken }` | the last 4 closed weeks; post again 1 per 10 min per week |
| `admin:previewSeasonEnd` | callback | seasons | — | champion, trophies, top 10; `server:admin:endSeason` now needs `confirm` = the season name |
| `server:admin:renameSeason`, `scheduleSeasonEnd`, `cancelSeasonEnd` | action | seasons | `{ id, name }` / `{ id, at, nextName?, reason }` / `{ id }` | the first daily reset on or after `planned_end` ends the season; reminders 24 h and 1 h before |
| `admin:previewReopen`, `server:admin:reopenSeason`, `undoReopen` | callback / actions | boardsAdmin | `{ id, reason, confirm = season name, previewToken, requestId }` / `{ jobId, reason }` | latest season, ended ≤ 24 h; the gap rows join it (J), Undo clears exactly that backfill |
| `admin:getSeason`, `admin:getDeptContributors` | callback | boardsAdmin | `{ id }` / `{ department, seasonId? }` | a past season; a department's contributors |
| `server:admin:setNextBounty` | action | bountyOverride | `{ objective }` | next week's bounty, while it has no winner |
| `admin:previewBountyRecount`, `server:admin:recountBountyWeek`, `admin:previewChampionRecount`, `server:admin:recountChampion` | callbacks / actions | boardsAdmin | `{ week \| seasonId, reason, confirm = 'RECOUNT', previewToken }` | old holder's unfinished reward cancelled before the new one is granted; champion ≤ 14 days after the end |
| `admin:getBoards` | callback (old) | openAdmin (+boardsAdmin for past windows) | `{ period = 'range', from, to }` or `{ seasonId }`, `metric` | whole weeks or months, ≤ 12 months back, 1 per 2 s; `windows`, `metrics` in the reply |
| `admin:searchOfficers` | callback (old) | openAdmin | `{ query, filters = { department, online, suspended, retired, excluded, review, dispute, flagged }, page }` | pages of 25; an online character with no row is found by its citizenid |

Hooks: fires `row:voided`, `row:restored`, `row:forfeitUndone`, `admin:changed`; listens to `settings:changed`
(`Leaderboard.*` → `LB.invalidate()`, `Profile.bannedWords*` → reload, `Challenge.*` → board webhook notice, `Goals.*`
→ logged; a period already rewarded stays rewarded) and `admin:changed` (`LB.invalidate()`). Sidebar counts:
`adminReview` (modules/profile) and `adminDisputes` (modules/disputes).

#### 8.4.2 Missions and the Mission Builder

Guards: P = `CP.AdminKit` permission (admins and the console only), R = reason, T = typed word, V = preview token,
K = compare-and-set, M = refused during maintenance (every action). Shapes: `web/src/types/admin_missions.ts`.

| Name | Payload → reply | Key | Guards |
|---|---|---|---|
| `server:builder:editBuiltin` | `{ id }` → `{ id, record, existing? }` (makes the override draft from the shipped file + MissionTweaks) | editBuiltins | P, `AdminControl.editBuiltins`; audit `overrideEdit` (builder) |
| `server:builder:keepOverride` | `{ id, reason }` → `{ id, changed = false }` | editBuiltins | P R K (`base_hash`); `overrideKeep` |
| `server:builder:resetBuiltin` | `{ id, reason, confirm = id, takeNew? }` → `{ id }` (Reset to original / Take the new original) | editBuiltins | P R T K; `overrideReset` |
| `server:builder:foldTweaks` | `{ id, reason }` → `{ id, version, tweaksCleared }` | editBuiltins | P R; `overrideFoldTweaks` |
| `admin:builtinDiff` (callback) | `{ id }` → BuiltinDiff (`original`: base copy → shipped; `yours`: shipped → override) | editBuiltins | P |
| `server:builder:publish` (existing) | an override row publishes as `overridePublish` / `publishUntested`; testing is never required of admins | editBuiltins for override rows | builder rules |
| `server:builder:changeOwner` | `{ id, citizenid, reason }` → `{ id, owner }` | missionAdmin | P R K; refused on overrides; `missionOwner` |
| `server:builder:deleteMission` | `{ id, reason, confirm = id }` → `{ id, folder }` (archived custom missions; not while a run, test or the operation uses it) | missionAdmin | P R T K; `missionDelete` |
| `server:builder:undeleteMission` | `{ folder, reason }` → `{ id }` (back as archived) | missionAdmin | P R; `missionUndelete` |
| `builder:deleted` (callback) | → `{ missions = DeletedMission[] }` | missionAdmin | P |
| `server:builder:loadBackupDraft` | `{ id, reason? }` → `{ id, version, record }` | missionAdmin | P; `draftRecovered` |
| `builder:versionDiff` (callback) | `{ id, version }` → VersionDiff (rollback picker; `server:builder:rollback` takes `version`) | builderRollback (as rollback) | builder rules |
| `admin:exportMissionLua` (callback) | `{ id }` → `{ id, version, lua }` (a built-in only through its override) | missionAdmin | P; `missionExport` |
| `admin:previewImport` (callback) | `{ lua }` (≤ 256 KB) → `{ previewToken, expiresAt, effect }` | missionAdmin | P, 1 per 10 s |
| `server:builder:importDraft` | `{ previewToken, reason }` → `{ id, record }` (a new draft, never published) | missionAdmin | P R V; `missionImport` |
| `admin:getMissionLoad` (callback) | → MissionLoadSummary | openAdmin | P |
| `admin:getMissionTweak` (callback) | `{ missionId }` → MissionTweakView | openAdmin | P |
| `server:admin:setMissionTweak` | `{ missionId, tweak?, reason? }` (no tweak = back to the file) → `{ missionId, tweak }` through `CP.Settings.set('MissionTweaks')` | openAdmin | P; `settingChanged` |
| `admin:trialMissions` (callback) | `{ patch = { { path, value? , none? } } }` → `{ checked, failed }` | openAdmin | P |
| `admin:getSwitchRemap` (callback) | → `{ missions = { id, label, stale, locations } }` | openAdmin | P |
| `server:admin:remapLocationSwitches` | `{ missionId, map = { { from, to = index \| false } }, reason? }` | openAdmin | P; `locationSwitch` |
| `admin:getMissionStats` (callback) | `{ from?, to?, missionId?, type? }` → MissionStatsData | openAdmin | P, 1 per 2 s |
| `admin:getOperations` (callback) | `{ from?, to?, status?, page? }` → Paged OperationHistoryRow (20 a page) | openAdmin | P |
| `admin:getMissionCalls` (callback) | `{ from?, to?, type?, area?, outcome?, issuer?, page? }` → Paged DispatchHistoryRow (25 a page) | openAdmin | P |
| `server:admin:mcCreate` (existing) | adds `skipWait = true, reason` (admins only) | missionCalls | R; `mcCreateSkipWait` (operations) |
| `server:admin:opLaunch` (existing) | adds `skipCooldown = true, reason` (admins only) | launchCrossDept | R; `opLaunchSkipCooldown` (operations) |
| `server:admin:markLocationChecked` | `{ missionId, locationIndex, tier?, reason }` → `{ id, location, tier }` | testRun | P R; `testMarkChecked` |
| `server:admin:hideTestResult` | `{ id, hidden, reason }` → `{ id, hidden }` | testRun | P R K (`hidden`); `testResultHide` |
| `admin:getTestHistory` (callback) | `{ missionId, locationIndex }` → TestHistory (hidden rows too) | testRun | P |

#### 8.4.3 Live runs, units and anti-farm

Callbacks (`CP.AdminKit.callback`; reads keep working during maintenance):

| Name | Args | Key | Returns |
|---|---|---|---|
| `admin:getLiveRuns` | – | `liveRuns` | `AdminLiveRunsData` (§9.5) |
| `admin:getUnits` | – | `liveRuns` | `AdminUnitsData` |
| `admin:getOfficerRunState` | `{ citizenid }` | `antiFarmOverride` | `AdminOfficerRunState` |
| `admin:getToday` | – | `liveRuns` | `AdminTodayData` |

Actions (`CP.AdminKit.action`; every one: M, P, R (reason required), A):

| Name | Payload | Key | Guards | Audit → webhook |
|---|---|---|---|---|
| `server:admin:recall` | `{ runId, src, reason }` | `liveRuns` | S (own run) → `Admin.forceRecall` | `forceRecall` → audit |
| `server:admin:endRun` | `{ runId, reason, confirm }` | `liveRuns` | T `END`, S (own run), not a test (`err.live_use_end_test`) | `runEnd` → operations |
| `server:admin:endTest` | `{ runId, reason }` | `liveRuns` | a test run only (`err.live_not_test`) | `testEnd` → builder |
| `server:admin:addRunTime` | `{ runId, minutes, reason }` | `liveRuns` | S; 1-10 min; timer running; total ≤ `runTimeAddMax` | `runTimeAdd` → operations |
| `server:admin:removeFromUnit` | `{ unitId, src, reason }` | `liveRuns` | not the admin's own unit; not locked, ready-checking or on a run | `unitRemove` → operations |
| `server:admin:disbandUnit` | `{ unitId, reason }` | `liveRuns` | as remove | `unitDisband` → operations |
| `server:admin:clearCooldowns` | `{ citizenid, scope ('all'\|'type'\|'mission'), key?, reason }` | `antiFarmOverride` | S; L 1 per 3 s per officer; K; per day | `cooldownClear` → flags |
| `server:admin:allowExtraRuns` | `{ citizenid, count, reason }` | `antiFarmOverride` | S; L; K; 1..`extraRunsMax`, once a day | `extraRunsAllow` → flags |
| `server:admin:grantBossAttempt` | `{ citizenid, reason }` | `antiFarmOverride` | S; L; K; once a week | `bossAttemptGrant` → flags |
| `server:admin:reclassifyAbandon` | `{ citizenid, runUuid, reason }` | `antiFarmOverride` | S (officer and run); a free abandon of the last 24 h | `abandonReclassify` → flags |
| `server:admin:setTypeOfDay` | `{ type (a type \| 'none' \| 'auto'), reason }` | `liveRuns` | Type of the Day on (`err.live_tod_off`) | `todOverride` → audit |

#### 8.4.4 Payments, item rewards and department money

Guards (§0.3 of the build plan): P = permission key, I = request id, R = reason, T = typed word, V = preview token,
S = never the admin's own characters or runs (strict: refused when a licence is unknown), W = a `Config.Cash.allow*`
/ `Cash.restoreForfeited` / `Rewards.allowTakeBack` switch that ships off (`err.money_tool_off`). M (maintenance) on
every action.

| Name | Payload / args | Key | Guards |
|---|---|---|---|
| callback `admin:getPayments` | `{ status?, department?, missionType?, citizenid?, from?, to?, page?, size? }` → PaymentsView | payments | P |
| callback `admin:getPaymentTotals` | `{ department?, from?, to? }` → PaymentTotals | payments | P |
| callback `admin:exportPayments` | the getPayments filters → `{ csv, rows, truncated }` | payments | P, 1 per 3 s, audited |
| callback `admin:checkBankingTxn` | `{ rowId }` → BankingCheck | payments | P |
| callback `admin:previewRetryUnfunded` | `{ rowId }` or `{ department, since? }` → UnfundedPreview | payments | P |
| callback `admin:previewCashSource` | `{}` → CashSourcePreview | payments | P |
| callback `admin:getDepartmentFunds` | `{ department }` → DepartmentFundsView | deptFunds | P |
| `server:admin:resolvePayment` | `{ rowId, outcome = 'paid' \| 'payAgain', checked?, reason, confirm?, requestId }` | payments | P I R S; payAgain: W `allowPayAgain`, `checked`, T the amount |
| `server:admin:payNow` | `{ rowId, requestId }` | payments | P I |
| `server:admin:retryPending` | `{ requestId }` | payments | P I |
| `server:admin:retryUnfunded` | `{ rowId \| department + since?, reason, confirm, previewToken, requestId }` | payments | P I R T(total) V S W `allowUnfundedRetry`; balance ≥ total; a department retry (and its preview, `excluded`) leaves out every row of the admin's own characters and runs, and rows whose officer's license is unknown |
| `server:admin:payCapRest` | `{ rowId, reason, confirm, requestId }` | payments | P I R T(rest) S W `allowCapTopUp` |
| `server:admin:repayForfeited` | `{ rowId, reason, confirm, requestId }` | payments | P I R T(amount) S W `restoreForfeited` |
| `server:admin:forfeitNow` | `{ rowId, reason }` | payments | P R S |
| `server:admin:cancelPayment` | `{ rowId, reason, confirm }` | payments | P R T(amount) S |
| `server:admin:clawback` | `{ rowId, amount, reason, confirm, requestId }` | payments | P I R T(amount) S W `allowClawback` |
| `server:admin:manualCash` | `{ citizenid, amount, reason, confirm?, requestId }` | payments | P I R S W `allowManualCash`; T above `maxPayout / 2`; 1..`maxPayout`; per admin (every character of their licenses, license: and license2:) per day ≤ `manualDailyLimit` (from rows); the row is written as `none` (no login payment or Pay now picks it up) and paid only after its audit row |
| `server:admin:addDepartmentFunds` | `{ department, amount, reason, confirm, requestId }` | deptFunds | P I R T(amount) W `allowAddFunds`; 1..`addFundsMax`; 1 per 10 s per department |
| callback `admin:previewPayoutAdjust` | `{ mode, value, scope }` → PayoutAdjustPreview | setTypePayout | P |
| `server:admin:adjustAllPayouts` | `{ mode, value, scope, lockTypes?, reason, confirm = 'ADJUST', previewToken, requestId }` | setTypePayout | P I R T V |
| `server:admin:setTypePayout` (existing) | gains `unlock?: boolean` | setTypePayout | as before |
| callback `admin:getRewards` (existing) | gains `{ citizenid?, status?, source?, from?, to? }` | openAdmin | as before |
| callback `admin:checkRewardInventory` | `{ id }` → RewardInventoryCheck | rewardsAdmin | P |
| callback `admin:rewardItems` | `{}` → RewardItemChoices | rewardsAdmin | P |
| callback `admin:rewardPoolPreview` | `{ path, value }` → RewardPoolPreview | rewardsAdmin | P |
| `server:admin:resolveReward` | `{ id, outcome = 'given' \| 'locker', reason, confirm? }` | rewardsAdmin | P R S; locker: T `LOCKER`; officer online |
| `server:admin:deliverRewards` | `{ citizenid }` | rewardsAdmin | P S; officer online |
| `server:admin:cancelReward` | `{ id, reason }` | rewardsAdmin | P R S |
| `server:admin:takeBackReward` | `{ id, reason, confirm, requestId }` | rewardsAdmin | P I R T(item) S W `Rewards.allowTakeBack`; officer online |
| callback `admin:getCleanup` | `{}` → CleanupView | cleanup | P |
| `server:admin:runCleanupNow` | `{ reason }` | cleanup | P R; 1 per 10 min; refused while a long job runs |

Audit actions (category `audit`, posted to the audit webhook; the money ones never dropped from a full queue):
`paymentsExport`, `paymentResolve`, `paymentPayAgain`, `paymentRetry`, `paymentUnfundedRetry`, `paymentCapRest`,
`paymentForfeitRepay`, `paymentForfeit`, `paymentCancel`, `cashClawback`, `manualCash`, `deptFund`, `payoutsAdjustAll`
(plus one `setTypePayout` / `setMissionPayout` per value), `rewardResolve`, `rewardDeliver`, `rewardCancel`,
`rewardTakeBack`, `cleanupRun`. Toasts: `cash.clawed_back`, `payments.toast.forfeited`, `payments.toast.cancelled`,
`rewards.taken_back`, `rewards.cancelled`, `payments.low_balance_toast`.

#### 8.4.5 System, departments and settings

Every name below is admin-only (supervisors never pass) and audited; `reason` is 1-255 characters where it is asked.

| Name | Payload → reply | Key | Guards |
|---|---|---|---|
| `admin:getStorage` | — → StorageView | storageAdmin | 1 per 5 s |
| `server:admin:storageCopy` | `{ direction, force?, confirm?, requestId }` → StorageCopyReply | storageAdmin | I, M, T `REPLACE` when forced, no runs, `storage` lock (kept until the restart when the store in use changed) |
| `server:admin:setStorageMode` | `{ enabled, folder?, startEmpty?, reason, confirm, requestId }` | storageAdmin | R, I, M, T `SWITCH`, no runs, folder under saves, target holds data or Start empty |
| `server:admin:useStoreAgain` | `{ reason, confirm }` | storageAdmin | R, T `USE`, only while `left_behind` (allowed during the lock) |
| `admin:getBackups` | — → BackupsData | storageAdmin | |
| `server:admin:backupNow` | `{ reason? }` → BackupView | storageAdmin | busy lock, 1 per 60 s per admin |
| `admin:previewRestore` | `{ name }` → RestorePreview (with `previewToken`) | storageAdmin | |
| `server:admin:restoreBackup` | `{ name, previewToken, reason, confirm, requestId }` | storageAdmin | V, R, I, M (allowed only during the lock of a restore that stopped part way), T `RESTORE`, no runs |
| `server:admin:deleteBackup` | `{ name, reason, confirm }` | storageAdmin | R, T the backup name, never the newest or latest pre-restore |
| `admin:getWebhooks` | — → `{ webhooks: WebhookView[] }` | openAdmin | read only, no link |
| `admin:getProblems` | `{ tag?, level? }` → ProblemsData | openAdmin | |
| `admin:getIntegrations` | — → IntegrationsData | openAdmin | |
| `admin:getDepartmentSetup` | — → DepartmentSetup | departmentsAdmin | |
| `server:admin:addDepartment` | `{ key, label, short, jobs, supervisorGrade, societyAccount?, themeFrom?, logo? }` | departmentsAdmin | the department validator (§5.36) |
| `server:admin:saveDepartment` | `{ key, fields }` | departmentsAdmin | the same |
| `server:admin:setDepartmentEnabled` | `{ key, enabled, reason, confirm }` | departmentsAdmin | R, T the short tag when turning off, not while its officers are on a run, never the last |
| `server:admin:deleteDepartment` | `{ key, reason, confirm }` | departmentsAdmin | R, T the short tag, added in game only, no rows |
| `server:admin:uploadLogo` | `{ department, uploadId, index, total, data }` → `{ received }` / `{ file, restart, linkRemoved? }` | departmentsAdmin | permission per chunk, one upload per admin, ≤ 1 MB, 60 s, PNG/WebP, 6 pieces a second (the client sends one every `Config.AdminControl.logoChunkGapMs`: FXServer drops a player past 128 KB/s of events); the last piece checks the settings (`logo.file`, and `logo.url` removed when set) before it writes the file |
| `server:admin:addDeskHere` / `updateDesk` / `removeDesk` | `{ label, size, rotation?, departments?, prop? }` / `{ index, ..., moveHere? }` / `{ index }` | departmentsAdmin | server position, the desk checks |
| `server:admin:teleportToDesk` | `{ index }` | departmentsAdmin | 1 per 5 s |
| `admin:myPosition` | — → `{ x, y, z, heading }` | openAdmin | server coordinates |
| `server:admin:teleportTo` | `{ path, index }` | openAdmin | coordinates from the stored setting, 1 per 5 s |
| `admin:checkAccess` | `{ src? \| citizenid?, via? }` → CheckAccessResult | playerSupport | 1 per 5 s per player |
| `server:admin:giveTabletItem` | `{ src? \| citizenid?, reason }` | playerSupport | R, 1 per 60 s per player, item set, none carried, not in the arena |
| `server:admin:releaseScreen` | `{ citizenid }` | playerSupport | 1 per 10 s per player |
| `admin:getClientState` | `{ citizenid }` → ClientStateView | playerSupport | 1 per 5 s per player |
| `admin:exportAuditPart` | audit filters + `{ part }` → AuditPartView | openAdmin | 1 per 3 s |
| `server:admin:saveAuditExport` | `{ filters }` → AuditSaveReply | openAdmin | 1 per 30 s |
| `server:admin:revertSetting` | `{ historyId, reason, again?, confirm? }` → SettingsReply | openAdmin | R; the Settings checks |
| `admin:exportSettings` | — → `{ text, count }` | openAdmin | |
| `admin:previewSettingsImport` | `{ text }` → SettingsImportPreview | openAdmin | ≤ 256 KB |
| `server:admin:importSettings` | `{ previewToken, reason, confirm, requestId }` | openAdmin | V, R, I, T `IMPORT` |

Events: `client:diagUnstick`, `client:diagState (token)` (server → one client), `server:diagState (token, state)`.

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
| `push` | `topic`, `data` | live data for open screens: `run`, `unit`, `board`, `operation`, `invites`, `test`, `builder`, `payouts`, and `calls` (DispatchView), `nav` (NavCounts), `profile` (own profile changed), `rewards` (locker changed), `contactConfirm`, `settings` (admins: a setting or switch changed, `{ paths }`), `spawnCheck` (the admin's spawn point check, §5.27); `unit` gains `readyCheck`, `run` gains `contact` |
| `overlay` | `overlay = null \| { kind: 'placement'\|'recording'\|'testdrive'\|'fade', ... }` | full-screen/HUD overlays |
| `theme` | `theme`, `locale?` | the department theme for the HUD (login, duty, job, unload); only the reply to `ready` carries `locale` (`CP.Locale.all()`), the NUI's one copy of the text |
| `locale` | `locale` | the whole locale again after `Config.Labels` changed (an open tablet shows the new names at once) |

Full admin control push topics: `maintenance` (MaintenanceView, `false` when the lock ended; every client) and
`adminjob` (AdminJobProgress; admin players only).

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
  locale?: Record<string, string>;                 // not sent: the NUI has the text from 'ready' (§9.1 theme)
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
  onRun: boolean;
  adminReview?: number; adminDisputes?: number; adminPayments?: number; adminLive?: number }   // admin players only
// Session gains maintenance?: MaintenanceView | null (CP.Maintenance.view()).
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
  route: null | { status: 'on' | 'off' | 'arrived' | 'disabled' | 'action'; secondsLeft: number | null; distance: number | null };
                                                   // 'action': a late partner follows the objective (PLAN M11)
  objectives: { label: string; done: boolean; current: boolean; detail?: string; value?: number; max?: number }[];
  detail: string | null;                           // client-side line for the current objective
  target: null | { label: string; distance: number; inside?: boolean }; // CP.Markers (§5.44): where the pointer leads, how far
  message: null | { text: string; kind: 'info' | 'success' | 'warning' | 'error' };
  testControls: boolean;                           // the admin who started the test
}
```

### 9.4 Officer screen data (callbacks)

```ts
// getMissionTypes
interface BoardCard { key: string; label: string; points: number; cash: [number, number];
  pool: number; mode: 'solo' | 'unit'; locked: null | { reason: string; until?: number };
  busy: boolean; onCall: boolean; typeOfTheDay: boolean; twists?: TwistOffer[] }
// the twists the leader may choose at the accept step (BoardData adds twistMax: { points; cash })
interface TwistOffer { key: string; label: string; desc?: string; points: number; cash: number; some?: boolean }
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
  expected: { cash: number; points: number }; modifier: HudState['modifier'];
  twists?: { key: string; label: string }[]; test: boolean;
  recalcsLeft: number; radioSilence: boolean; silenceMode?: 'none' | 'area' | 'full' | null;
  log: null | { point: number; choices: { id: string; label: string }[] } }
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

Full admin control (web/src/types/admin_control.ts; each package's own shapes are in types/admin_<area>.ts):

```ts
interface MaintenanceView { kind: 'storage' | 'restore' | 'left_behind'; since: number; restart?: boolean; by?: string;
  failed?: boolean; automatic?: string }   // failed: a restore stopped part way; automatic: the backup to restore
interface AdminJobProgress { id: string; kind: string; state: 'running' | 'done' | 'failed' | 'rolledback';
  done: number; total: number }
interface AdminActionBase { requestId?: string; reason?: string; confirm?: string; previewToken?: string }
interface AdminPreview<E> { previewToken: string; expiresAt: number; effect: E }
interface MoneyEffectLine { label: string; amount: number; before?: number }
// slot components (the host screen renders them; the owning package fills them):
interface OfficerSlotProps { citizenid: string; online: boolean; officer?: unknown; onChanged?: () => void }
  // admin/components/OfficerRunControls (P3), OfficerSupport (P5), in Officers → officer detail
interface DepartmentSlotProps { department: string }          // DepartmentFunds (P4), each department card
interface RewardPoolSlotProps { path: string; value: unknown; disabled?: boolean; onSave: (v: unknown) => unknown }
  // RewardPoolEditor (P4) with handlesRewardPool(path): Settings uses it for the paths it handles
// MissionsToday (P3, no props): Missions → catalog tab
```

Missions and the Mission Builder (web/src/types/admin_missions.ts): `OverrideView` (builder:list `builtins[].override`,
`BuilderListEntry.override`: overridden, shippedHash, baseHash, version, hasDraft, status, tweaks, loadError?, changed),
`BuiltinDiff`, `VersionDiff`, `MissionLoadSummary`, `MissionTweakView`, `SwitchRemapData`, `Paged<R>` with
`OperationHistoryRow` / `DispatchHistoryRow`, `MissionStatsData`, `DeletedMission`, `ImportPreview`, `TestHistory`.
`TestLocationStatus` gains `checked`; `TestMissionRow.switch` is the mission's `MissionSwitchView`. The admin pieces
of Admin UI → Missions live in `web/src/builder/admin/`.

Live runs, units and anti-farm (web/src/types/admin_live.ts; P3):

```ts
interface AdminLiveRun { runId; missionId; missionLabel; missionType; state; tier; remaining: number | null;
  timerRunning: boolean; paused: boolean; timeLimit: number; timeAdded: number; test: boolean; testBy?: number;
  operationId: number | null; isBoss: boolean; modifier?: string; acceptedAt; startedAt?; unitId?; departments: string[];
  own: boolean; participants: { src; citizenid; name; callsign; departmentShort; status; arrived; endReason? }[] }
interface AdminLiveRunsData { runs: AdminLiveRun[]; serverTime; addMinutesMax: number; runTimeAddMax: number }
interface AdminUnit { id; leader: number; members: { src; name; callsign; rank; departmentShort; leader; joinedAt?;
  onRun }[]; invites: number; locked: boolean; readyCheck?: { typeLabel }; runId?; createdAt; blocked?: errKey;
  own: boolean }
interface AdminOfficerRunState { citizenid; online; onRun; runId?;
  cooldowns: { types: { key; label; until }[]; missions: { id; label; until }[] }; clears: { used; max };
  counts: { today; maxDay?; hour; maxHour; perType: { key; label; n; limit? }[] };
  extra: { n; usedToday; max }; cashToday; boss: { enabled; used; extra; left; grantedThisWeek };
  freeAbandons: { runUuid; missionType; typeLabel; missionLabel; at }[];
  board?: { cards: { key; label; pool; busy; onCall; typeOfTheDay; locked?: { reason; until? } }[];
    boss?: { available; locked?: { reason } }; operation: boolean; serverTime; unitSize } | null; serverTime }
interface AdminTodayData { day; todEnabled; typeOfTheDay: string | null; typeLabel?; rolled: string | null;
  override?: { type; by?; reason?; at? }; todMultiplier; boss: { enabled; today; days };
  modifierChance; modifiers: { key; label; armedOnly?; enabled; points?; cash? }[]; types: { key; label }[] }
```

The admin kit (web/src/admin/components/kit): `useAdminAction()` (`run(name, payload, { requestId? })` adds a fresh
`requestId`), `newRequestId()`, `OfficerPicker`, `DateRangeField`, `Pager`, `PreviewTable`, `JobProgress` /
`useAdminJob(jobId)`, `MoneyEffect`, `RowsEditor` (on `SettingView.rows`). `ConfirmDialog` takes `effect` and
`typedWord` (Confirm stays off until the word matches; `onConfirm(reason, typed)`). `MaintenanceBanner` shows on every
UI; `useMaintenance()` (shared/session.tsx) follows the session and the push. New admin screens: `admin_payments`,
`admin_live`, `admin_system` (stubs until their packages fill them).

Economy (web/src/types/admin_economy.ts; the item reward shapes in types/rewards.ts):

```ts
interface PaymentRow { id: number; runUuid: string; citizenid: string; name?: string | null; missionId: string;
  missionLabel: string; missionType: string; manual: boolean; department: string; status: CashStatus; owed: number;
  paid: number; reclaimed: number; cut: number; txn: string; account?: string | null; source?: 'server' | 'society' | null;
  step?: 'claimed' | 'withdrawn' | 'added' | null; restPaid?: string | null; again?: string | null; voided: boolean;
  flagged: boolean; busy: boolean; createdAt: number }
interface PaymentsView { rows: PaymentRow[]; page: number; pages: number; total: number; size: number;
  switches: { payAgain; unfundedRetry; capTopUp; restoreForfeited; clawback; manualCash; addFunds: boolean };
  source: 'server' | 'society'; maxPayout: number; manualDailyLimit: number; nextForfeitIn?: number | null;
  held?: string | null; serverTime: number }
interface PaymentTotals { byStatus: Record<CashStatus, { count; paid; reclaimed; owed: number }>;
  departments: { department: string; count; paid; reclaimed; unfunded; share: number }[]; paidTotal: number;
  cut: number; cappedToday: number; partial: boolean }
interface BankingCheck { id; status; txn; amount; step?; source?; account?; societyAccount?;
  personal?: { found: boolean; amount?: number; type?: 'deposit' | 'withdraw'; time?: number } | null;
  society?: (same) | null; busy: boolean; online: boolean; payAgain: boolean }
// UnfundedPreview, DepartmentFundsView, CashSourcePreview, CleanupView, PayoutAdjustPreview: see the file.
// types/rewards.ts: AdminRewardsFilter, RewardInventoryCheck, RewardItemChoices, RewardPoolPreview; RewardRow gains
// rowId and online; AdminRewardsView gains allowTakeBack. types/economy.ts: outOfRange, supervisorRange, unlock.
```

System (web/src/types/admin_system.ts, P5): StorageView, StorageCopyReply, BackupView, BackupsData, RestorePreview,
WebhookView (category, convar, state, discord, line; never the link), ProblemsData, IntegrationsData, DepartmentSetting,
DepartmentSetup, DepartmentFields, CheckAccessResult, ClientStateView, AuditPartView, AuditSaveReply. Settings
(web/src/types/settings.ts): `SettingsHistoryRow` is a cp_settings_history row (path, action, old/new with
oldSaved/newSaved, short texts, by, byName, reason, revertsId, latest, canRevert); SettingsExport,
SettingsImportPreview; SettingKind adds `goals`; SettingsData adds `resets`, `safeMode`, `added`.

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
- The UI reads the same strings via `t(key, vars)`: the client sends them once with the reply to `ready` (the
  `theme` message) and again as `locale` after a `Config.Labels` change. Sessions carry no locale.

## 11. Verification (every slice must pass before it is done)

`tools/check_all.sh` runs every check below in one command; `docs/TESTING.md` covers the set-up and how to
read a failure.

- `luac5.4 -p` on every Lua file it wrote.
- `python3 tools/lint_fivem.py`: the FiveM pitfall rules (wrong-side natives, late `source`, client `os`/`io`,
  unguarded focus release, raising callback awaits, orphan mode, `os.rename` answers, server `os.execute`,
  CRIMSON_ARENA natives, loops that can go round with no Wait (FX10, `tools/lua_flow.py`), debug functions FXServer
  does not have (FX11), a server yes/no answer compared with `true` (FX12)); deliberate uses and bugs
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
  `return H` at the end. `H.fire` gives each dispatch one cancelled flag (`CancelEvent()`, `WasEventCanceled()`, and
  its return value), as FXServer's TriggerEvent2 does. `H.combatNatives(onCall)` installs the NPC combat and damage
  natives with natives.json's argument types (a float where the game reads a float, and so on; a wrong one fails the
  spec) and returns what each one set, per ped and per game (`world.forget(ped)`, `world.restore()`); `H.gaitNatives(onCall)`
  does the same for the movement natives of a runner (the task, the per-frame cap and move rate, the clip set,
  GetSafeCoordForPed), `H.groundNatives(onCall)` for the natives of a ground probe on a small map the spec
  builds (ground surfaces found only once the collision loaded, interiors that get ready after a pin or never,
  water, asynchronous wall capsules, model sizes), and `H.placerNatives(onCall)` for the natives of the placer
  (players, network ids, control that comes after a request or never and can be taken over, freeze and coordinates
  kept only on an entity this game controls). Specs run in separate processes, two at a time (`--jobs=N`), each on its own copy
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
