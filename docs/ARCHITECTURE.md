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
   is the admin's storage copy (`/CrimsonPoliceAdmin storage copy`, §5.29). Resource KVP holds only the storage
   choice made in game (§5.29) and this PC's local officer options (§5.48), never game data.
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
      `source == 'crimson-police'`. **The full, verified rule set is the Crimson-Arena section of `docs/INTEGRATIONS.md` (mandatory):**
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
  docs/ARCHITECTURE.md             this file: code structure, module APIs and notes (§5), events, storage, the web UI (§12)
  docs/SPEC.md                     the product spec (markdown)
  docs/INTEGRATIONS.md             checked facts about the other resources, and the Crimson-Arena rules
  docs/TESTING.md                  the checks, CI, working on the code; docs/IN_GAME_CHECKLIST.md what to check in game
  docs/LOOPS.md, docs/WORKFLOWS.md every loop and timer; every workflow and the spec that drives it
  docs/STYLE.md                    the code style
  docs/FILE_NOTES.md               one line per source file, what it is for (written by tools/restyle.py)
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
    shared/options.lua             CP.OptionDefs: the officer options registry and its rules (§5.48)
    shared/options_board.lua       Mission Board: favourite types first, hidden types folded, one-click accept (§5.48)
    shared/options_dispatch.lua    Dispatch and opening: one-click claim, call pop-ups, key after a call, open on (§5.48)
    shared/options_hud.lua         The mission HUD's officer options: side, size, compact, fewer animations (§5.48)
    shared/options_look.lua        Easier to read: the tablet look on the HUD, larger text (§5.48)
    shared/options_run.lua         During a mission: abandon in two presses, one-click recalculate, miles (§5.48)
    shared/options_popups.lua      Pop-ups: toast time, result card time, fewer pop-ups on a run, key hints (§5.48)
    shared/options_sounds.lua      Sounds: mission call tone, unit tone, objective cues on or off (§5.48)
    shared/options_unit.lua        Unit: Auto-Ready answers the unit ready check near the leader (§5.48)
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
                                   §12
    sql/migrations/001_initial.sql, 002_test_def_hash.sql, 003_run_stats.sql, 004_profile.sql,
                   005_mission_calls.sql, 006_item_rewards.sql, 007_settings.sql, 008_admin_control.sql,
                   009_real_suspects.sql, 010_officer_options.sql, 011_dept_controls.sql,
                   012_mission_ban.sql, 013_call_department.sql, 014_live_catches.sql,
                   015_field_training.sql, 016_saved_cases.sql, 017_lookup_indexes.sql
```

fxmanifest loads: `@ox_lib/init.lua`, config/config.lua, config/blocks.lua, shared/*.lua
(alphabetical: init, locale, net, npccombat, options, twists, utils), then `modules/**/server.lua` (server) /
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

More folders (all in the spec's Feature folders table; §5.30–§5.34):
`modules/custody/` (server, client), `modules/missioncalls/` (server, client), `modules/profile/` (server),
`modules/rewards/` (server), `modules/confighealth/` (server), `modules/integrations/sc_police/` (server),
`blocks/field_contact/` and `blocks/process_scene/` (server, client).

`modules/diag/` (client, §5.35): the F8 command `CrimsonPoliceState`, with the freeze fix
(§5.15).

`modules/npccombat/` (client, server, §5.42): the run-scoped damage settings of an officer's game (Config.NpcCombat), the
protection drop and the `crimsonPoliceRun` player bag.

`modules/markers/` (client, §5.44): the current objective's pointer on the officer's map and its one GPS line
(Config.Markers).

`modules/missionblips/` (client, server, §5.53): the extra mission blips of every other part of a mission
(Config.MissionBlips, shipped off).

`modules/spawn/` (client, server, §5.43): what an officer's game can see of the spawn director's points
(Config.Spawning.preferHidden), the ground probe of one point (Config.Spawning.ground), the placer that puts a
new mission entity on the ground when the server asks (Config.Spawning.place), and the server's side of it: the ask
written for every new mission entity, the answers, another point after a bad one, the time limit.

`modules/settings/` (server, client, §5.36): settings changed in game (Admin UI → Settings) over config.lua and
blocks.lua, the mission and location switches, and the same values on every client.

`modules/adminkit/` (server, §5.37): full admin control's foundation. `CP.AdminKit` (the guard wrapper of every new
admin action, previews, request ids, jobs, day counts, the busy lock) and `CP.Maintenance` (the maintenance lock).
Full admin control also has `modules/corrections/` (§5.38), `modules/livectl/` (§5.39), `modules/payments/`
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
| `CP.Net.callback(name, handler, opts)` | shared/net.lua | server: ox_lib callback `crimson-police:<name>`; handler `(src, args) -> data` or `nil, errKey`; reply `{ok,data,error}`. After a failed start every callback answers `err.not_started` before its handler runs. `opts.latent = true` (the three big exports `admin:exportAudit`, `admin:exportAuditPart`, `admin:exportPayments`; `Kit.callback` passes it through): when the client sent a reply id (the callback's second argument after `args`), the data goes as `TriggerLatentClientEvent('crimson-police:client:actionResult', src, Config.Limits.exportBps, id, true, data)` and the callback answers `{ ok = true, latent = id }`, so up to 5000 CSV rows no longer hold back the admin's other events (`exportBps` 200000; below 100000 counts as 100000; 0 = one plain answer) |
| `CP.Net.rateOk(src, key, max, windowMs)` | shared/net.lua | server: a token bucket per (src, key): `max` calls at once, then one back every `windowMs / max` (a new key starts full; `playerDropped` clears the player's buckets). `CP.Net.action` (`opts.rate`, default 8 a second) and `CP.Net.callback` (default 6) answer `err.rate_limited` past it. `Config.Limits.netRateResponse` (read at each refusal): `'block'` (shipped) refuses quietly; `'log'` also prints one `CP.warn('net', ...)` a minute per player once one name is refused 3 x its limit (at least 20) in a minute, never for an admin (`CP.Access.isAdmin`); `'kick'` prints that warning and calls `DropPlayer(src, CP.L('err.rate_kick'))` once |
| `CP.Net.action(name, payload, timeoutMs)`, `CP.Net.request(name, args, opts)` | shared/net.lua | client; both return `{ ok, data, error }` and never raise (`err.timeout` after timeoutMs, default 15000; `err.no_response` when ox_lib raises). `opts` is the timeout in ms or `{ timeoutMs, latent = true }`: latent sends a reply id (from the `actionResult` ids) and, on a `{ latent = id }` answer, waits up to 60 s more for that latent `actionResult`. The tablet's NUI `request` path always passes `latent = true`; the NUI waits 90 s (`EXPORT_TIMEOUT_MS`, `request(name, args, { timeoutMs })`) for the three exports instead of its 20 s |
| `CP.NpcCombat.*` | shared/npccombat.lua | Config.NpcCombat read at every call (§5.42): `weapon(name)`, `ammo()`, `isAutomatic(name)`, `automatic()`, `automaticsIn(t)`, `weaponsAllowed(list, allowed)`, `capAccuracy(acc)`, `scaleAccuracy(acc)`, `shootRate()`, `firingPattern()`, `ability(a)`, `noCharge()`, `driveByAccuracy(acc)`, `driveByPattern()`, `aiDamage()`, `aiMeleeDamage()`, `reassertAiDamage()`, `officerDefense()`, `noCriticalHits()`, `cancelLethalHeadshots()`, `lethalCancelAbove()`, `enabled()` |
| `CP.OptionDefs.*` | shared/options.lua | Officer options (§5.48), Config.OfficerOptions read at every call: `add(key, { kind = 'bool'\|'enum'\|'list'\|'number', values = list \| function, default, min, max, integer, store = 'server'\|'local', group, order })`, `remove(key)`, `get(key)`, `keys()`, `values(key)`, `check(key, value, bounds, { drop }) -> clean \| nil, errKey` (enum/list membership, lists de-duplicated, numbers clamped; `drop` drops list entries no longer offered), `same(a, b)`, `enabled()`, `resolve(deptKey) -> allow, defaults, bounds` (the option's default <- Config.OfficerOptions <- the department's officerOptions), `checkConfig(t) -> nil \| 'err.option_config', key` |
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
| `protect_rescue` | 15 | `npcs` (location key: list of vec4) · `count` [3] · `peds` · `restrained` [true] · `freeTime` [6000] ms · `target = { label = 'Cut restraints' }` · `safe` (location key vec3) · `safeRadius` [6.0] · `hitPenalty` [50] · `failIfDies` [true] · the hostages appear when this objective starts, through the spawn director (`Config.Spawning.hostagesAt` 'objective'; 'runStart' or `enabled = false`: in `prepare`, when the run moves to In progress) |
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
| `search_area` | 60 | `center` (vec3 key) · `startRadius` [600] · `shrinkTo` [{300,150,50}] · `clues` (list key, 6+) · `clueCount` [3] · `clueProps` (`'witness'` = a witness NPC) · `clueProgress = { label, duration = 4000 }` · `hiding` (vec4 list key, 6+) · `fugitives` [1] · `runDistance` [30.0] · `givesUp = { stun = true, close = { distance = 3.0, seconds = 3 } }` · `escape = { distance = 300, seconds = 30 }` · `cuff = {...}` · each fugitive and clue appears once an officer is near it, through the spawn director (`Config.Spawning`; `enabled = false`: all when the search starts) |

Each block's `server.lua` exposes `defaults(obj)` and `validate(obj, mission, location)` so the
loader and the Mission Builder apply exactly these defaults and guardrails.

A block may also expose `stage(ctx, dt)` (§7.1, `Config.Spawning.stageAhead`): the engine calls it while the objective
before this one runs, so the block can place this objective's people ahead of time. No common field turns it on: a
block that stages decides from its own fields which objectives it stages. `hostile_waves` stages an objective with
`stage = true` (the raids' fights): wave 1 through the director (`ctx.whenNear`, `ctx.choosePoints` with the
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

`flee_arrest` through the director (`Config.Spawning.enabled`): every associate and inmate gets a point of
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
(5 m) of as near taken in `st.routeOrder` from his turn on; off, `st.routeOrder` in turn. `Config.Spawning.leaveOutAfter` (and at least
`waveDelayMax`) short while someone of the objective has appeared and every one of them is done: the missing ones are
left out (`st.leftOut`, one `CP.warn` `<n> inmate(s) left out: ...`; `AssocTarget` / `InmateTarget`, the checklist and
the HUD count without them). A door location with no `suspect` point: nobody at the door (`st.noSuspect`, one
`CP.warn`), never the start point. `enabled = false` or `associatesAtKnock = false`: associates at the
objective's start; the ring with `enabled = false`). The suspect a surrender stands at the door step (`MoveToDoor`,
server `SetEntityCoords`) is asked to be placed again there: `CP.Spawn.again` (§5.43).

Worn-out runners (Config.Flee, not a file field): next to its own close rule, each block that owns a runner calls
`CP.Npc.wornOut(netId, near)` with its own nearest-participant distance and, on true, its own surrender (state
`surrendered`, the bag task it returned, Cuff suspect), with no wait: `flee_arrest` for every ped in `'fleeing'`
(armed ones too, before the fire-range rule could turn an armed inmate hostile; a surrendered suspect's feint waits
while wornOut is true), `pursuit` for a suspect in `'fleeing'` in stop mode only (follow mode has no arrests),
`search_area` for a fugitive in `'fleeing'`, `field_contact` for a contact in `'fleeing'` who is not walking off a
consensual contact. The escape rules are unchanged.

field_contact through the spawn director (Config.Spawning): a scene (scene mode: its car and every person, all at once) and each parked car (parked
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
`RETURN_WALK_S` + distance / 1 m/s; the thief runs at `thief.runAt`. `enabled = false`: nothing changes
(scene and cars at once, the driver 14 m and the thief 30 m from the car at a random angle, at once).

pursuit through the director (Config.Spawning). `PlaceFor(ctx, st, i)` returns slot i's point, its console name
(`spawnOffset -200 m, 8 m back`, `spawns[3]`, `route[12]`, `50 m ahead of the start`) and, for spawnOffset, the slot's
base (`OffsetSpot`: `{ p, label, watch }`, kept in `st.offset` once the first car is out, so the next cars queue
behind it). A point of the road route itself (spawnOffset's `AlongRoute`, a loop's waypoint, an open route's first
point, and the queue copies of them) gets `Config.Spawning.vehicleLift` on z (`Lifted`); the file's `spawns` / `spawn`
points are used as written. A spawnOffset < 0 objective on an open route that an earlier pursuit objective of the
mission with a spawnOffset on the same route precedes (`LaterViolator`: Traffic Enforcement's objective 3) counts from
the participant furthest up the road among those within `ON_ROAD` (100 m, 2D) of it (`RoadSpot`: his metres along the
route on the nearest segment) and is placed `secondViolatorUpstream` metres before him (`AtRoad`, never before the
route's first point); `st.watchFrom` = his road point is then where `WatchCruise` judges "passed" instead of the start.
No participant on the road, `secondViolatorUpstream = 0` or the director off: from the start. No start: one
`CP.warn` and the spawnOffset branch is skipped (the next ones: spawns, spawn, ahead of the start, the route), never a
player's position. `SpawnVehicle` offers `Candidates` (slot i, then the slots `vehicles + 1` and `vehicles + 2`, none
within `SLOT_TAKEN` 4 m of a car of the objective; labelled `vehicle <i> at <name>`) to `ctx.choosePoints(cands, 1,
{ name, wave = 'vehicle <i>', since = st.waitMs[i], ordered = true })`: the first that passes is used, the rest that
pass go to `spawnVehicle` as `alt` (the placer's other points, §5.43); none passes: no car this tick (SpawnMissing tries
again each tick, the objective waits). `enabled = false` or no `ctx.choosePoints`: slot i at once.

escort through the director (Config.Spawning). `SpawnTruck` takes `TruckSpot(ctx, st)`: route[1] (heading to route[2]) and `TRUCK_SPOTS` (4) spots
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
once; `ambushAheadOnly = false`: the own slot only, through the director.

search_area through the director (Config.Spawning). `start` and each `tick` call `SpawnMissing`,
which plans the clues (`PlanClues`, `cl.name` = `clues[5]`) and the hiding order (`st.order`) once, then `SpawnNear`
(in a pcall, `st.spawning` cleared always). Fugitive i has his own spot from the start (`Slot(i)`: point `order[k]`,
the `REUSE_OFFSET` ring per lap, named `hiding[3]`); `FugitiveAnchor` counts a fugitive who has not appeared
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
search starts.

protect_rescue through the director (Config.Spawning).
With `hostagesAt = 'objective'` (shipped) `prepare` makes nothing; the hostages appear when the objective starts
(`start`, then each `tick` for the ones still missing): once `ctx.whenNear` says an officer is within `activateRange`
of the middle of their points, `SpawnDirected` offers every free spot (`Slot(i)`: hostage i on point `order[k]`, the
`REUSE_OFFSET` ring per lap, named `hostages[3]`) to `ctx.choosePoints(offer, #offer, { name = 'the hostages
(<key>)', wave = 'hostages', since = st.waitMs, centre, indoor = true })`: minDistanceIndoor (15 m) from every
officer, never behind one (no line-of-sight ask: every spot is asked for). The spots it refuses wait (`st.waitMs`,
counted while an officer is near); after `hostagesWaitMax` (10 s; 0 = never) the rest appear on their spots anyway
with one `CP.warn` naming the mission, the place, the nearest officer's distance and the setting (they are tied up and
unarmed, and the rescue cannot go on without them). `st.slots[i]` marks the spots used, `st.spawned` counts them. A
location with no hostage points spawns nobody, with one `CP.warn` (never the start point). `hostagesAt =
'runStart'` or `enabled = false`: in `prepare` on every spot in order, with the retry thread
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
  -- also kept by modules/runs
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
| `downed_case` (a downed officer of a live crime, `Config.RealSuspects.downed = 'keep_earned'`; the lines earned so far) | completed | **no** | yes | yes (with `downed` in keepPayTierFor) |
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
   objective starts unstaged. Read live: switched off mid-run, nothing more is staged and what was placed stays.
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

Signatures are `CP.X.fn(args) -> returns`. "S" = server, "C" = client. Functions marked *(hook)* are called by other
modules at the named moment. Functions that may query the database must be called from a thread (they may yield).
Each module's file header documents its public API in full; each section here gives what the module is for, its API,
its events and storage, and the rules that are not obvious from the code.

### 5.1 Integrations (only these touch outside resources)

Checked facts about the other resources (signatures, payloads, pitfalls) are in `docs/INTEGRATIONS.md`; implementers
of `modules/integrations/*` follow it. Files: `modules/integrations/{qbx,sc_dispatch,sc_ambulance,renewed_banking,
sc_police}/`, `tests/core_spec.lua`. Every listener (server and client, all integrations) runs in its own
`CreateThread` inside `pcall`, so it may query or wait without holding up the other resource's dispatch.

**CP.Qbx** — modules/integrations/qbx
- S `getPlayer(src)` (raw qbx player, never cached); `getInfo(src) -> { src, citizenid, name, firstname, lastname,
  job = { name, label, type, onduty, gradeLevel, gradeName }, gang, callsign, metadata, isDead, inLastStand, license }
  | nil`, reused for `Config.Limits.playerInfoCacheMs` (1000; 0 = no cache) and cleared by every qbx_core event below,
  `playerDropped` and a qbx_core restart; each caller gets its own copy of the top level and `job`. `callsign` is nil
  for a missing value, `''` and `'NO CALLSIGN'` (trimmed, not clipped); `gradeName` falls back to the job definition.
- S `getByCitizenId(citizenid) -> src|nil`; `getOnlinePlayers() -> { src }` (ascending; one `GetQBPlayers` copy at
  start, when qbx_core starts and every 60 s, kept by load/unload/drop in between; with `playerInfoCacheMs = 0` every
  1 s); `knownJob(src) -> jobName|nil` (the primary job qbx_core last reported, from its events, `getInfo` and the
  `GetQBPlayers` copy; never feeds `CP.Access.onLost`); `getJobs()`.
- S `addMoney(src, account, amount, reason) -> bool, 'error'?` (rounded half up; 0 = true without a call; negative,
  NaN or infinite = false; `'error'` when `AddMoney` raised: the balance may have changed, never retry or refund),
  `getMoney(src, account)`, `removeMoney(src, account, amount, reason) -> true | false | false, 'error'`.
- S `isDowned(src)` (`metadata.isdead` or `inlaststand`, read with `exports.qbx_core:GetMetadata`, falling back to
  `GetPlayer` on a Qbox without that export).
- S listeners: `onDutyChange(fn(src, onDuty))` (a `true` is re-read from PlayerData first, so a stale `true` arrives as
  `false`; listeners still re-read before acting), `onPlayerLoaded`, `onJobChange(fn(src, job))` (job in the
  `getInfo` shape), `onPlayerUnload`, `onGroupUpdate`, `onMetaDataChange(fn(src, key, old, new), keys?)`. Sources:
  `QBCore:Server:SetDuty`, `QBCore:Server:PlayerLoaded`, `QBCore:Server:OnJobUpdate`, `QBCore:Server:OnPlayerUnload`,
  `QBCore:Player:SetPlayerData`, `qbx_core:server:onGroupUpdate`, `qbx_core:server:onSetMetaData` — all server-local:
  **AddEventHandler only, never RegisterNetEvent** (clients could spoof them).
- S read-only lookups, always on the real oxmysql (`CP.Storage.realMySQL` with the database off), never with a cp_
  table in the statement, nil or `{}` on error (one error line a minute): `plateOwned(plate)` (`player_vehicles`; only
  to reroll a mission plate), `licenseOf(citizenid)`, `characterExists(citizenid)`, `citizenidsOfLicense(license)`
  (at most 20), `userLicenses(license)` (that license, then the `license`/`license2` of the Qbox `users` row that has
  it; just `{ license }` without that table).
- C `getPlayerData()` (`{}` while `LocalPlayer.state.isLoggedIn == false`), `onJobUpdate(fn(job))` (also on
  `qbx_core:client:onGroupUpdate`, the only event when the active job is removed), `onDutyChange`, `onUnload`,
  `onLoaded`.

**CP.Dispatch** — modules/integrations/sc_dispatch (S)
- `available()`, `isSuspended(citizenid, jobName)`, `normalizeCallId(id) -> string` (`123`, `'123'`, `123.0` →
  `'123'`), `lookupActiveCall(callId) -> uniqueId|nil` (`mdt_dispatch` by id or unique_id, active; nil when
  sc-dispatch is stopped; the numeric form only for digit-only ids; an empty unique_id returns the row id; `npccall-`
  rows are returned, the caller classifies), `clearNotification(uniqueId, jobs) -> bool` (pcall; refuses numbers and
  digit-only strings, which would match unrelated rows by id).
- `realCallSummary() -> { total, p1 } | nil` (active real calls by priority, excluding `Config.Calls.npcCallPrefix`;
  cached `Config.MissionCalls.realCallCache` s), `mdtCommendations(citizenid) -> list|nil` (`employee_incidents`
  commendations, last 10; `Config.Profile.showMdtCommendations`). Read-only.
- Listeners: `onResponding(fn(src, callId, isResponding))` (`sc-dispatch:server:ToggleResponding`, callId as sent,
  validated, at most 64 characters), `onCallCleared(fn(callId))` (server-local), `onDispatchRestart(fn())`
  (sc-dispatch start or stop wipes every call), `onShotsFired`, `onPlayerDown`, `onPlayerDead` (`fn(src, data,
  receivedAt)`; data is a sanitised `{ coords, street, zone, sex }`, client-supplied, so distance checks use server ped
  coords; no coords = dropped). Net listeners are rate limited per player (ToggleResponding 6/s, the alerts 5/s).

**CP.Ambulance** — modules/integrations/sc_ambulance
- S `doctorCount()` (min of `GetDoctorCount()` and the live on-duty `ambulance` count; 0 with one error log when
  sc-ambulance is stopped).
- S `revive(src) -> bool` → `TriggerClientEvent('hospital:client:Revive', src)`; refuses non-integer, non-positive,
  disconnected and in-arena ids (an error in that check refuses too), sends nothing while sc-ambulance is stopped.
- C `sendEMSRequest() -> bool` → `hospital:server:EMSDownAlert` from the downed player's own client; at most once per
  5 s, false while the local player carries Crimson-Arena's flag.
- S `on('respawn', fn(src, hospitalIndex)) -> bool` (real suspects): a second, read-only
  `hospital:server:RespawnAtHospital` handler; returns at once without a listener or while `CP.Opponents.active()` is
  not true, rate-limits 6/s, index 1..255, each listener in pcall, never yields, never answers a hospital:* event.

**CP.Banking** — modules/integrations/renewed_banking (S)
- `recordDeposit`, `recordWithdraw` (a clawback), `recordSocietyWithdraw`, `recordSocietyDeposit` (all `(account or
  citizenid, amount, message, issuer, receiver, transId)`), `withdrawSociety(account, amount)`,
  `depositSociety(account, amount)`, `societyBalance(account)`, `findTxn(transId, { citizenid, account }) -> {
  personal, society }` (entries `{ found, amount, type, time }` read from `player_transactions` / `bank_accounts_new`
  on the real oxmysql, only that `trans_id`; not found proves nothing: Renewed-Banking writes history only for a
  cached player).
- Never raise; return booleans (`societyBalance` a number or nil). 0 amounts send nothing and return true. Texts cut
  to message 200, issuer/receiver 100, transId 128 bytes (never inside a UTF-8 character); `'` and `\` removed from
  the message; title `Config.Tablet.title`.

**CP.ScPolice** — modules/integrations/sc_police (S)
- A second, read-only `police:server:Impound` handler: a live run's vehicle → `CP.Runs.noteExternalRemoval(netId, src,
  'sc_impound', dist)`. `onImpound(src, netId) -> bool`.
- `on(kind, fn) -> bool` (real suspects), listen-only handlers for `CuffPlayer` → `'cuff'` (officerSrc, targetSrc,
  isSoftcuff), `UncuffPlayer` → `'uncuff'`, `CuffBreakAlert` → `'cuffBreak'` (suspectSrc, officerSrc), `EscortPlayer`
  → `'escort'`, `JailPlayer` → `'jail'` (jailTime raw, the listener clamps), `BobbyPinResult` → `'bobbyPin'` (pickerSrc,
  success), `SeizeCash` → `'seizeCash'`. Each: `local src = source` first, returns at once without a listener or an
  active case, `CP.Net.rateOk(src, 'scp:' .. kind, 6, 1000)`, ids must be 1..65535, listeners in pcall and must not
  yield. `police:server:SetHandcuffStatus` is never registered (cuffs come from the `ishandcuffed` metadata). It never
  triggers, cancels or answers a police:* event.

### 5.2 CP.Access — modules/access
Who is an officer, of which department, with which role. Tests: `tests/core_spec.lua`.
- S `departmentForJob(jobName) -> deptKey|nil` (turned-on departments only; a job in two departments belongs to the
  first key, with a warning), `offDepartmentForJob(job)` (the turned-off department that lists it).
- S `department(key)`, `departments()` (sorted, copies, turned-off ones included with `enabled = false` so their pay
  still finds the society account) → `{ key, label, short, jobs, supervisorGrade, societyAccount, enabled, theme = {
  primary, accent, background, surface, text }, logo = { url, file, watermark, opacity, size, grayscale } }`. Invalid
  colours fall back to the Crimson-Police default (`Config.AdminTheme` / web `DEFAULT_THEME`), one warning per
  department and key; an invalid or missing `text` is picked with `CP.U.contrastText(background)`. `logo.url` (https)
  wins over `logo.file` (a bare png/webp/svg/jpg/jpeg name, served as `https://cfx-nui-<CP.resource>/logos/<file>`);
  `size` clamped to 0.05-1. No numeric `supervisorGrade` = no supervisors (warning); `societyAccount` defaults to the
  first job name.
- S `getOfficer(src) -> officer|nil, errKey` — loaded character, active job in a turned-on department, on duty, not
  suspended (Crimson-Police or SC-Dispatch, cached 15 s), not retired (`cp_officers.retired_at`). Errors
  `err.not_police`, `err.department_off`, `err.not_on_duty`, `err.suspended`, `err.suspended_dispatch`, `err.retired`.
- S `maybeOfficer(src)` — a pre-filter for loops over every player, no Qbox lookup: false only when
  `CP.Qbx.knownJob(src)` is in no turned-on department. Loops never call `GetPlayer` per player.
- S `isAdmin(src)` — `IsPlayerAceAllowed(src, adminAce())`, or the ace `admin` while `Config.QboxAdmins == true`
  (explicit true only); src 0 (console) = true. Every admin check goes through it. `adminAce()` (`Config.AdminAce`,
  else `'crimsonpolice.admin'`), `qboxAdminAce()`.
- S `isSupervisor(src)`, `role(src) -> 'admin'|'supervisor'|'officer'|nil`.
- S `recheck(src, jobName) -> ok, endReason` — `'off_duty'|'job_change'|'suspended'` for a player on a run who no
  longer qualifies (a different active job, or one outside every department, is job_change); true for a player
  without a character (the drop path ends the run).
- S `onLost(fn(src, endReason))` — fired on qbx duty/job events and from `suspend()` for a player whose last known job
  (seeded on start, load, getOfficer, recheck and every qbx event) was a department job. Listeners decide whether the
  player is on a run.
- S `isSuspended(citizenid) -> bool, untilTs`; `suspend(citizenid, days, actorSrc, reason, opts) -> ok, errKey` (0 days
  lifts; whole days 0-3650 or `opts.untilTs`; a player actor needs `can(actorSrc, 'suspend')`, console/anticheat skip
  it; the end is capped at 2147483647 because MariaDB's `FROM_UNIXTIME` gives NULL beyond; `err.internal` when it
  cannot be stored; the caller writes the audit; the online officer gets a toast). `isRetired(citizenid)`,
  `dispatchSuspension(citizenid, jobName?) -> { suspended, available }`.
- S `refreshOfficerRow(src)` — upserts `cp_officers` callsign, rank_label, display_name, department and license
  (never clears a known license) on character load, on a department job update and on tablet open; off-duty members
  too, civilians get no row. Text limits (name 64, callsign 32, rank 40, label 64, short 16) are cut in bytes without
  splitting a UTF-8 character (MariaDB strict mode refuses a half character).
- S licenses: a player has `license:` and usually `license2:`, and Qbox stores each character under one of them, so
  every `GetPlayerIdentifierByType` passes the type with its colon. `licenseOfSrc(src)`, `licensesOfSrc(src)`,
  `licenseOf(citizenid)` (`cp_officers.license`, else `CP.Qbx.licenseOf`; 15 s cache), `selfCitizenids(src)` (the
  current character, then every row and character of his licenses), `sameUser(a, b)` (one Qbox `users` row has both).
- S `explain(src, via?) -> { ok, error?, steps = { { check, ok, vars? } }, ... }` — the opening checks in order (job,
  department on, duty, suspended, SC-Dispatch, retired, arena, the way); the verdict is `getOfficer` then
  `CP.Tablet.checkAccess`, so it never disagrees with a real open.
- Hook `admin:changed { citizenid }` drops that officer's suspension, retirement and license caches.
- S export `GetDepartment(src)` (the active job's department, on duty or not).
- C `current()`, `department()`, `roles()`, `setSession(session)`, `clear()` (used by the tablet).

### 5.3 CP.Permissions — modules/permissions (S)
- `can(src, action, ctx) -> bool, errKey` (`err.no_permission`). Admins and the console: true for any action.
  Supervisor: `CP.Access.isSupervisor(src)` (or an extra grant, below) and `Config.Permissions.supervisor[action] ==
  true`. `ctx.runUuid` applies the own-run rule to `reviewFlagged`, `handleDisputes`, `handleFailedDispute`,
  `voidAnyRun` (admins included, `err.own_run`); `ctx.department` / `departments` keep supervisors to their department
  (`err.other_department`). `viewMissionList` and `fieldTraining` belong to every supervisor.
- Admin-only keys (no supervisor switch can give them; mirrored in modules/admin's ADMIN_ONLY for the Permissions
  screen): `setMissionPayout`, `clearPayout`, `manualAward`, `handleFailedDispute`, `voidAnyRun`, `seasons`,
  `bountyOverride`, `suspend`, `reloadMissions`, `testRun`, `openAdmin`, `officerRecords`, `pointsAdjust`, `bulkVoid`,
  `restoreRun`, `progression`, `antiFarmOverride`, `liveRuns`, `editBuiltins`, `missionAdmin`, `boardsAdmin`,
  `payments`, `rewardsAdmin`, `deptFunds`, `departmentsAdmin`, `storageAdmin`, `playerSupport`, `recordMove`,
  `cleanup`. `isAdminOnly(action)`, `adminOnlyKeys()` (the 29, in order).
- `actionsFor(src)` (for the session; a granted officer's switched-on granted powers, which open the Supervisor UI
  with only those screens).
- `tookPart(citizenid, runUuid, asSuspect)` — any live or archived row of that run (a failed lookup counts as taking
  part); `asSuspect` also counts a real suspect of the run's case (`CP.Opponents.suspectOfRun`).
  `canReviewRun(src, runUuid)` — false when the reviewer or any character of his licenses took part (`err.own_run`).
- `probe(src, name)` — a non-admin asked for an admin-only action: one `CP.warn('security', ...)` per player and name a
  minute, at most `Config.AntiCheat.adminProbeLines` (5) a minute per player (0 = none). No officer or supervisor path
  asks an admin-only key of a non-admin.
- `gradeGrant(officer, { minGrade = N } | { grades = { ... } })` (`Config.Permissions.builderTeleport`,
  `Config.MissionControls.grants`).
- Extra grants (`Config.Permissions.grants`, Admin UI → Permissions → Extra grants, saved as the setting
  `Permissions.grants`): `{ [power] = { departments = { [dept] = gradeGrant }, gangs = { [gang] = gradeGrant },
  citizenids = { ... } } }`. `isGrantable(power)` (a supervisor switch key or `builderTeleport` / `fieldTraining`; never
  admin-only or `viewMissionList`), `grantableKeys()`, `granted(src, power)`, `grantedFor(src)`. The switch, the
  department check and the review self rule still apply. Used by `CP.DeptControls.canChange` (a `missionControls`
  grant skips `Config.MissionControls.grants`), `CP.Builder.canTeleport` and field training pairing. Admins never come
  from a grant. Shipped `{}`.

### 5.4 CP.Tablet — modules/tablet (owns the NUI)
Files: `modules/tablet/server.lua`, `modules/tablet/client.lua`; items/ (the tablet image and the ox_inventory entry
an owner pastes, client.export `Crimson-Police.useTablet`; never loaded by the resource).

Server:
- callback `getSession(args)` → Session (§9.2), 4/s per player. `args = { ui = 'officer'|'supervisor'|'admin', via =
  'command'|'keybind'|'item'|'export'|'desk'|'dispatch', desk = index, silent }`. The Supervisor UI is for officers at
  or above `supervisorGrade`, granted officers and on-duty admins (`roles.supervisor` is the same rule);
  `session.officer` is filled whenever the player qualifies, also in the Admin UI. The silent session (the HUD theme at
  login) opens nothing, skips the access checks and `refreshOfficerRow`. Session extras: `officer.avatar`,
  `officer.level`, `prefs`, `access = { via, desk }`, `maintenance` (§5.37), and the config values `dispatch`,
  `leaderboardMetrics`, `profile`, `commendationKinds`, `rewards`, `format`. nil fields arrive in the NUI as missing
  keys.
- `checkAccess(src, officer, via, desk)` — every Officer and Supervisor open ends here after `CP.Access.getOfficer`:

| Rule | Error |
|---|---|
| The way's `Config.Tablet.access` switch is false (dispatch follows keybind; item also needs `Config.Tablet.item`; export is always on) | err.access_off |
| `CP.Alerts.inArena(src)`, every way | err.in_arena |
| Desk: no such `Config.Tablet.desks` index, or the ped (server coords) is outside the box grown by 2 m (`rotation` turns it) | err.not_at_desk |
| Desk: the desk lists departments and not the officer's | err.desk_department |
| requireItem: every way but a desk needs the item (ox_inventory Search in pcall; a failure or a stopped ox_inventory = no item) | err.no_tablet_item |

  An unknown `via` is the command; a request that names no way (switchUi, refreshSession) uses the src's last passed
  way. Helpers `desk(i)`, `deskAllows(desk, dept)`, `inDeskBox(desk, coords, margin)`, `hasTabletItem(src)`.
- `itemOk(src)` — requireItem again for `server:acceptType` and `server:claimMissionCall`: true when requireItem is
  off, when the last way was a desk and the ped is still within `deskDistance` + 2 m of its box, or when the item is
  there now.
- `notify(src, kind, key, vars, { title, duration })` (kind info|success|warning|error), `notifyMany(srcs, ...)`,
  `push(src, topic, data)` (NUI `{ type = 'push' }`), `pushAdmins(topic, data)`, `notifyAdmins(kind, key, vars)`,
  `onlineAdmins()` (only admins, never anyone else), `openAdmin(src)` (`false, 'err.not_in_game'` from the console).
- Sidebar badges: `navCounts(src) -> NavCounts`, callback `getNavCounts`. Counts: invites, calls
  (`CP.MissionCalls.claimableCount`), review (supervisors: flagged rows, disputes, profile queue; 30 s cache),
  commendations, rewards, onRun, and the ones other modules add with `registerNavCount(key, fn(src, officer|nil),
  { adminOnly })` (`adminReview`, `adminDisputes`, `adminPayments`, `adminLive` go to admins only). Each through a
  guarded call (a missing module gives 0); the set is cached 5 s per src. A push of unit, invites, calls, profile or
  rewards clears the cache and, for a src that asked in the last 10 minutes, schedules one `nav` push 1 s later; a
  `run` push does so only when the run starts or ends or once per `Config.MissionCalls.eligibilityCache` s.
  `navChanged(src)` schedules one.
- Plain events: `server:tabletClosed` (4/s; ends the nav watch, fires `tablet:closed`), `server:tabletItemGone` (2/s;
  with requireItem on, not at a desk and the item really gone → `client:closeTablet` with the errKey),
  `server:logoFailed` (a department key or `{ department, url }`; one warning per logo).
- Logos: checked at start with `LoadResourceFile` once the saved settings are loaded. `logoFor(dept)`: clients load
  only files FXServer packed at start, so a logo file that was not a start file keeps the start logo (or none) until
  the restart; `session.logo` is nil without a valid logo.
- Callback `admin:getTabletAccess` (admins) → TabletAccessView (web/src/types/access.ts): ways, item, deskDistance,
  desks, each department's personal accents and the appearances.

Client:
- `/CrimsonPolice` (`Config.Tablet.command`, toggles the Officer UI), key mapping `crimsonpolice_tablet` (always
  registered, default `Config.Tablet.keybind`, `''` = unbound), `crimsonpolice_dispatch` (`Config.Tablet.dispatchKey`:
  opens or switches to Dispatch), the ox_inventory item (`Config.Tablet.item`), export `OpenTablet()`.
- `open(ui, { via = 'export', desk, screen })`, `close()`, `isOpen()`, `send(msg)`, `notify(kind, text, opts)`,
  `hud(patch)` (shallow merge; `false` clears `modifier`, `timer`, `route`, `message`, `detail`; `hud(nil)` hides),
  `result(result)`, `overlay(o)`, `push(topic, data)` (local), `registerClientAction(name, fn(payload) -> ok,
  data|errKey)`. NUI callbacks: `ready`, `close`, `request`, `action` (forwards only `server:` names), `client`,
  `switchUi` (§9.1).
- `switchUi` replies the new Session and sends an `open` for the new UI; a UI closed meanwhile stays closed
  (`err.tablet_closed`). The prop stays between officer and supervisor and goes for admin.
- Prop and animation: `Config.Tablet.prop`, a local object on bone 60309, animation
  `amb@code_human_in_bus_passenger_idles@female@tablet@base` (flag 49), re-applied every second while open.
- Mission desks: one ox_target box zone per desk (`crimson-police:desk`), created once, shown only to an on-duty
  officer of an allowed department with the tablet closed outside Crimson-Arena (display only: the server decides),
  with an optional local laptop prop; removed on resource stop and on a foreign arena flag, created again after. At a
  desk no prop: `Config.Tablet.deskScenario` plays and the tablet closes beyond `Config.Tablet.deskDistance` (checked
  every 0.5 s). With requireItem the client checks the item every second while open (not at a desk) and reports its
  loss once.
- Down (`isdead` / `inlaststand`, or a dead ped, `playerDown()`): the Officer and Supervisor UIs refuse
  (`err.downed`) and close within 0.5 s, so no NUI focus is held under sc-ambulance's screens. The Admin UI is exempt.
- Every `open` carries `seq`; once the NUI said at `ready` that it confirms (`{ acks = true }`), an open not confirmed
  with `opened { seq }` within 6 s closes the tablet and releases the focus. The NUI itself hands the focus back when an
  open cannot be shown or a layout crashes (§9.1).
- The `theme` message (always a theme, the default for non-officers, plus `locale`) goes at login, after duty/job
  changes (debounced 1.5 s), on unload and on NUI `ready` (which also re-sends HUD, overlay and open UI). On
  `settings:changed` with new `Config.Labels` the NUI gets `{ type = 'locale' }`.
- Crimson-Arena (rule 8): a foreign `crimsonArena` value closes every UI, hides HUD, overlays and the result card and
  cancels a progress bar (`lib.progressActive` first); while it is foreign every way to open refuses with
  `err.in_arena` and a result card that arrives is dropped (the run stays in the Profile history).
  `SetNuiFocus(false, false)` only when a UI was open.
- Closes on job/duty loss and character unload. The tablet client does not handle `client:hud` / `client:runEnded`.

### 5.5 CP.Schedule — modules/schedule (S)
Times are server local; the "day" starts at `Config.Time.resetHour`. Day, week and month arithmetic uses `os.time`
date normalisation, so DST never shifts a day. Tests: `tests/engine_a_spec.lua`.
- `now()`, `dayKey(ts?) -> 'YYYY-MM-DD'`, `dayStart(ts?)`, `weekStart(ts?)` (resetHour on
  `Config.Leaderboard.weekStartsOn`), `weekKey(ts?)`, `monthStart(ts?)`, `weekday(ts?) -> 'monday'..'sunday'`,
  `sqlTime(ts)`.
- `onDaily(fn(dayKey))`, `onWeekly(fn(weekKey, prevWeekStartTs))`, `onMonthly(fn(monthStartTs))` — once when the
  boundary passes (checked every 60 s; never just because the resource started; a clock moved back to an earlier day
  fires nothing, with a warning).
- `onDailyJob(fn(dayKey))` — a long job per daily reset (the daily backup): after the daily listeners the jobs run one
  after another in one thread, then the retention job, so listeners and the next boundary check never wait (a reset
  that comes while the previous jobs still run is skipped with a warning).
- Retention job, at each daily reset and once 120 s after start (idempotent): `cp_mission_runs` rows older than
  `Config.Retention.runArchiveMonths` move to `cp_mission_runs_archive` (`INSERT IGNORE ... SELECT`, then a DELETE of
  only the rows whose archive copy matches, cash status and amount paid included), never a row whose money or item
  reward is unfinished (held, pending, paying, giving); `cp_audit` and `cp_settings_history` older than
  `Config.Retention.auditDays` are deleted (0 = off), `cp_admin_requests` after 7 days. It waits up to 60 s for the
  busy lock (`CP.AdminKit.waitIdle`, else `skipped = 'busy'`) and holds it (`cleanup`); during a maintenance lock it
  and every boundary check wait (`skipped = 'maintenance'`).
- `cleanupView() -> CleanupView` (§9.5), callback `admin:getCleanup`, action `server:admin:runCleanupNow { reason }`
  (§8.4.4).

### 5.6 CP.Missions — modules/missions
The mission registry. Files: `modules/missions/server.lua`, `client.lua`; tests `tests/engine_a_spec.lua`,
`tests/missions_a_spec.lua`, `tests/missions_b_spec.lua`.

Server:
- `loadAll()` — waits for `CP.Migrations.ready()` (so built-ins are normalised with the settings changed in game),
  reads `missions/builtin/index.lua` and each built-in with the mission file reader, then `CP.Builder.loadPublished()`
  (its file sync runs first) and `CP.Builder.loadOverrides()`; normalises and validates each, keeps the valid ones,
  warns about the rest, then broadcasts `client:missions` (`TriggerLatentClientEvent`, 200000 B/s; the 14 built-ins
  are about 60 kB). A custom entry may be a definition with loader fields, `{ def, meta }`, or meta only (then the
  loader reads the file); `defHash` is the file's hash, else a canonical hash of the definition. If `loadPublished`
  throws, the custom missions already loaded stay.
- Edited built-ins (§8.4.2): each override replaces its built-in under the same id (`source = 'builtin'`,
  `overridden`, `overrideVersion`, `baseHash`, `shippedHash`); a broken override is logged, listed in
  `overrideFailed`, and the shipped mission plays. `Config.MissionTweaks` apply on top.
- `reload() -> summary` (`/CrimsonPoliceAdmin reload` and `server:admin:reloadMissions`: `can(src,
  'reloadMissions')`, 1 per 5 s, audited) calls `CP.Builder.onReload()` first (hand edits become new versions). The
  summary: `{ loaded, builtin, custom, warnings, failed = { { id, file, error } }, overridden, overrideFailed,
  warningTexts (first 200), builder, at }`; `loadSummary()` (callback `admin:getMissionLoad`, Config health
  `missions`).
- `get(id)`, `all()`, `list()`, `byType(type)` (no boss), `isEnabled(id)` (published, not archived, not in
  `Config.DisabledMissions`, at least one location on), `isLocationEnabled(id, index, map?)`
  (`Config.DisabledLocations[id]` by label, an alias in the location's `aliases`, or number), `enabledLocations(def)`,
  `label(def, field, n)` (§10), `rawOf(id)`, `refreshBuiltin(id)` (runs going keep their definition).
- `register(def)` / `unregister(id)` — the Builder's publish/archive without a reload; `register` refuses to replace a
  built-in; `unregister` removes custom missions only (built-ins are turned off in `Config.DisabledMissions`).
- `registerEngine(def)` / `engine(id)` — a mission the engine builds itself (`live_crime`, §5.46), normalised with
  `meta.engine` (may use an engine-only block) in its own registry: the draw, `client:missions` and the Builder never
  see it, and `register` refuses its id.
- `normalize(def, meta) -> def|nil, err` (English developer text, not locale keys), `parse(luaSource, chunkName)` (the
  raw definition; chunkName with or without `@`), `serializeForClient(def)`, `checkTweak(id, tweak) -> ok | false,
  errKey, reason` (CP.Settings asks it on every change made in game), `trial(patch) -> { checked, failed }` (every
  mission through the loader with a settings patch, put back before it returns), `stats(args)` (callback
  `admin:getMissionStats`, 60 s cache per filter).
- callback `getMissionDefs` (`nil, 'err.not_ready'` before the first load; the client retries 12 times from 3 s to
  15 s and ignores a reply once a push arrived). Client: `CP.Missions.get(id)`.

`normalize` rules:
- Rejected: an id that is not `^[%a][%w_]*$` or longer than 40; no label; a type not in `Config.MissionTypes` (the
  Weekly Boss is forced to `tactical`); not `1 <= minOfficers <= maxOfficers <= Config.Limits.maxUnitSize`; difficulty
  outside 1..#`Config.Difficulty.pointsByStars`; `timeLimit`/`startTimeout` outside 60–3600 s; `cooldown` outside
  0–86400 s; no location with `start = { coords, radius }` (a bare vector becomes radius 50 with a warning); no
  objective; an unknown block or a block `validate` that fails for any location; an item named `armour`, `bandage`,
  `ammo-*` or `weapon_*` (Crimson-Arena rule 4); any point (start and every data key, recursively) inside a
  `Config.Builder.noBuildZones` zone (2D); engine-only bonus ids.
- The loader fields (`source`, `isBoss`, `status`, `version`, `filePath`) are set before the blocks' `validate`,
  which exempts built-ins (`source == 'builtin'`) from the Builder's model and weapon lists.
- Warnings only (the Builder enforces them for custom missions): fewer locations than expected (built-in 5, or 3 for
  `armored_truck_escort`, `evoc_course`, `weekly_boss_kingpin`; custom `Config.Builder.minLocations`), locations
  closer than `minLocationGap`, more armed NPCs than `maxHostiles`, more objectives than `maxBlocks`, unknown
  departments, a scaling base above its `max`.
- Dropped with a warning: scaling entries that do not resolve to a number or list of numbers, nameless items, bonus or
  penalty ids not in `Config.Bonuses` without their own points; every payout-like top-level key (`*payout*`, `cash`,
  `cashBase`, `basePay`, `money`, `pay`, `reward`, `rewards`).
- Defaults: `description = ''`, `departments = {}`, `minOfficers = 1`, `maxOfficers = minOfficers`, difficulty and
  cooldown from `Config.Blocks.details[...][3]`, `startTimeout = Config.Limits.startTimeout`, `vehiclePenalties =
  true`, `minSeconds` from §3.3, `presenceRange = Config.Blocks[block].presenceRange[3]` (fallback
  `Config.AntiCheat.presenceRadius`), labels `run.objective_default` / `run.location_default`.
- Kept: `quietPatrol`, `decisions`. `Config.MissionTweaks` (cooldown, timeLimit, startTimeout, disabledLocations,
  peds, vehicles, weapons) are applied and re-validated.

The mission file reader (shared/utils.lua). Mission files are data and are never run: FXServer's Lua is built with
`LUA_SANDBOX` (no `debug.sethook`), so running text could not be stopped and could reach CfxLua's own C functions.
- `CP.U.parseMissionFile(text, chunk) -> def|nil, err` (the single `RegisterMission(...)` call's table),
  `readMissionCalls(text, chunk)` (every call's value), `readMissionReturn(text, chunk)` (`return <value>`, for
  index.lua).
- Accepted: comments; `RegisterMission(<table>)` or `RegisterMission <table>`; `;`; nil, booleans, numerals as Lua's
  lexer cuts them, every Lua 5.4 string form; tables with name, `[string|number|boolean]` or positional keys;
  `vec3`/`vector3` of 3 numbers and `vec4`/`vector4` of 4. A UTF-8 BOM is skipped; a key given twice is refused.
- Refused with `<chunk>:<line>: <reason> near '<text>'`: any other name, operator or call, `local`, `function`,
  CfxLua's extra syntax, any malformed token. Limits (`CP.U.missionFileLimits`): 1,048,576 bytes, 100,000 values,
  tables 32 deep; linear time; it never touches the string metatable, the GC or `_G`.
- Used by every path that turns a file into a definition: built-ins, index.lua, custom files, overrides, the
  Builder's read-back, drafts and backups, `ShippedOf`, `admin:previewImport` (`err.import_parse`), CP.Testing.

#### Built-in missions
There are 19 in `missions/builtin/index.lua`. Files: `missions/builtin/*.lua` (each a header comment and one `RegisterMission({ ... })` in the Example-file field
order; no payout field; `departments = {}`), checked by `tests/missions_b_spec.lua`.

| Mission | Locations | Per location |
|---|---|---|
| warrant_service | 6 houses: Grove Street, Forum Drive, Mirror Park, Wild Oats Drive, Sandy Shores, Paleto Bay | door, suspect (on the step beside the door), 4 fleeTo, 4 associates, yard |
| manhunt | 5 regions: Sandy Shores, Grapeseed, Paleto Bay, Harmony, Grand Senora Desert | start radius 600, 6–7 clues, 7 hiding spots |
| gang_shootout | 5 hideouts: Stab City, Grand Senora scrapyard, Paleto sawmill, Terminal, Elysian Island | 14 spawns facing the approach, scene |
| hostage_rescue | 6 Fleeca banks | 7 hostile spots, 3 hostages, safe marker outside |
| bomb_disposal | 6 24/7 stores | 7 hiding spots at floor level |
| armored_truck_escort | 3 routes: Del Perro → Hawick (1.87 km), Route 68 Harmony (0.87 km), Banham Canyon → Chumash (0.86 km) | route { points, stops }, 5–7 ambush points |
| prison_break | 6 breakout points outside Bolingbroke | 8 inmate spawns, 2–3 escape routes |
| weekly_boss_kingpin | 3 compounds: Madrazo ranch, O'Neil Ranch, Marlowe Vineyards | 18 spawns, boss, scene (in front of the main house) |

- Interior points (Fleeca, 24/7) come from well-known anchor positions plus offsets and are the most reliable. Rural
  spots are estimates on open ground with z a little high (a ped drops rather than sinks). Nothing is placed behind a
  facade without an interior (a ped there is stuck, a target unreachable).
- **Check in game with Admin test mode before release**, in this order: the three truck routes (straight-line
  waypoints every ≤ 140 m between anchors; the escort passes a waypoint within 20 m, so re-record them with the
  Builder's route recorder), the gang hideout rings (Terminal and Elysian Island first: a point can land in a
  container), the Kingpin compounds, the prison terrain heights, the manhunt spots.
- The spec's guardrails (checked by the test): counts, 100 m spacing, map bounds (x −4000..4600, y −4200..8000), every
  point and path segment outside `Config.Builder.noBuildZones`, points 30 m+ from and within 150 m of their start
  (except manhunt, road and escape routes), z within 8 m of the start (25 m for routes and manhunt), hostile headings
  facing the approach, door headings facing the street, contiguous flee paths and escape routes (no jump over 250 m),
  prison points 180 m+ from the zone centre and 230 m+ from the prison middle, a route waypoint every 150 m, ambush
  spacing, the armed budget (Kingpin 30 + boss ≤ 40), escape routes 150 m clear of the Crimson-Arena Skydome.
- File choices: hostile_waves objectives leave `spawns` out (default `'spawns'`); flee_arrest scatter writes it.
  Door-mode `knock.duration = 3000`. Kingpin `cooldown = 1200` (the weekly limit is `CP.Events.bossAvailable`). Boss
  surrender `{ belowHealth = 0.25, chance = 0.30 }` so "arrested alive" can happen (`kingpin_alive` from the block
  default). Bomb prop `prop_c4_final_green`; manhunt clues `prop_cs_heist_bag_02`, `prop_npc_phone_02`, `'witness'`.
  Escort waves and cars `max = 5`.
- `minSeconds` is a floor honest play cannot reach (more than 1 s under it flags the whole run `too_fast`): hostage
  hostiles 12, hostage rescue 8, warrant 8 (3 s knock + 5 s cuff), Kingpin waves 90, bomb search 3, defuse 5, escort
  45 (the shortest route takes about 52 s), others the block default.

- The five field-contact missions:

| Mission | Type, officers | Locations | Objectives |
|---|---|---|---|
| parking_patrol | patrol, 1, quietPatrol | 7 districts × 10 kerb spots | field_contact parked (`parking` truths) |
| suspicious_activity | investigation, 1–2 | 7 scenes: car, people, fleeTo, transport | field_contact scene |
| traffic_enforcement | patrol, 1–2 | 7 corridors, each with a `speed` key | pursuit observe + handoff; field_contact stop; the same pair again with `team = 2` |
| drug_lab_raid | tactical, 2–4 | 7 rural labs, 250 m clearance | breach together; waves (inside/yard sets); cooks (`cook_arrested`); stash seize (`stash_found_fast`); shut-down skill_check with a setback (`lab_fire`); process_scene |
| gang_hideout_raid | tactical, 2–4 | 7 hideouts | breach together; waves (front/house/garage sets) + lieutenant boss (`lieutenant_alive`); runners; cache seize; process_scene |

  Geometry came from the GTA vehicle-node graph (kerb spots on the straightest non-freeway edge; corridors touching a
  no-build zone were rejected). **Check in game before release:** kerb spot headings, the lab and hideout interiors,
  the corridor speeds. Retrofits: stolen_vehicle_takedown (responses 25/65/10, handoff, `profileSet = 'stolenCar'`,
  `driveBy = 50`, a field_contact stop, `vehicle_impounded`), warrant_service (yard finds 60 %, process_scene),
  gang_shootout (process_scene, 4 bodies), beat_patrol and business_check (`quietPatrol`).
- Zone lint (`tests/zone_lint_spec.lua`): a footprint is a location's start and every point (a route by its two ends);
  new missions keep `Config.Draw.zoneClearance` (200 m) from every other footprint (drug_lab_raid 250 m), no point in a
  no-build zone; the known close pairs are in `tests/zone_lint_baseline.txt` (a new pair fails; `BASELINE_MAX` stops it
  growing).
- Spawn lint (`tests/spawn_lint_spec.lua`): no two spawn points of a location within 1.5 m, a point for each person the
  largest team brings (real `CP.Scaling` counts), armed spawns outside the start circle plus
  `Config.Builder.spawnMargin` unless the director places them (waves, scatter, staged); known cases in
  `tests/spawn_lint_baseline.txt`, which may only shrink.
- Setup coordinates (`tests/setup_coords_spec.lua`): each shipped mission desk and downed drop-off names its
  source place (tests/fixtures/foreign_sites.lua) on its config.lua line and stays within 3 m of it; the Sandy
  Shores desk has no Qbox source and is listed as kept.
- Other scripts' places (`tests/foreign_sites_spec.lua`): no built-in start or spawn point inside the keep-out circle of
  a fixed place of a public Qbox or ox script (`tests/fixtures/foreign_sites.lua`, written by
  `tools/gen_foreign_sites.py`): 6 m round a garage, vehicle spawn or job spot, 4 m round a hospital, station or
  prison point, 2 m round an ox_target spot, or the script's own radius up to 10 m; no baseline.

### 5.7 CP.Draw — modules/draw (S)
Which mission and location a unit gets, and the accept. Tests: `tests/engine_a_spec.lua`, `tests/missioncalls_spec.lua`.
- `pool(missionType, members, opts) -> { def }, reasonKey` — published, enabled, type match, open to every member's
  department, supports `#members`, off per-mission cooldown for every member; `opts.area` keeps missions with a
  location in that area.
- `draw(missionType, members, opts) -> def, locationIndex | nil, reasonKey` — no-repeat (below), then `pickLocation`;
  a mission with no location tries the type's next mission.
- `pickLocation(def, srcs, rng, opts) -> index|nil`, rules in order: reservations, a location turned off,
  `opts.exclude` and `opts.area` (hard); zone clearance (`Config.Draw.zoneClearance` from every point of every held
  location of any mission; soft, but never within `Config.Draw.hardClearance`); `opts.avoid` and each participant's
  last `Config.Draw.avoidLastLocations` locations of that mission (soft); player clearance
  (`Config.Draw.playerClearance`, soft, ignores in-arena players); then a weighted pick (half weight for a spot taken
  within `Config.Draw.locationFreshness`; `opts.nearCoords` weights by `1 / (1 + km /
  Config.MissionCalls.countyWeightKm)`). A turned-off location counts in no area. `footprint(def, index)` (start and
  every point, routes sampled every 50 m), `_locationOn(def, i)`.
- `reserve(runId, missionId, index)`, `release(runId)`, `isReserved(missionId, index)` — several holders per spot.
  `acceptType` holds a provisional `pending:<src>:<ms>` reservation around `CP.Runs.create`; a 60 s sweep releases
  pending holders older than 60 s and unknown holders older than 120 s.
- No-repeat: per citizenid the distinct missions of the type with completed or abandoned rows, newest first, plus a
  15-minute in-memory `recordLast(citizenid, missionType, missionId)`; the unit avoids the union of every member's
  last `Config.Draw.avoidLast` (`avoidLastLarge` when the pool has `largePool`+ missions). When the histories cover the
  whole pool it relaxes to `avoidLast`, then to "not anyone's latest", then the whole pool; a pool of one repeats. If
  every candidate's locations are in use the accept fails with `err.no_location`. `noRepeat(list, hist)`,
  `history(citizenid, type)`, `recordLocation`, `locationStats(missionId)` (callback `admin:getLocationStats`).
- `boardCards(src) -> BoardData` (§9.4; callback `getMissionTypes`): one card per `Config.MissionTypes` key by config
  points; `points` = the pool's best `CP.Scoring.P(def)`, `cash` = `CP.Cash.range(key, officers)` (with fallbacks),
  `typeValues(type, officers, list)`. `locked` priority: a member not an officer > type cooldown (`until`) > hourly cap
  > daily cap (`locked.daily`, `until` = next day start) > empty pool (`board.locked_empty[_solo]` or
  `board.locked_mission_cooldown`). `onCall` when a member is on a real call; `callsOpen`. While
  `CP.Operations.isLocked()` only `operation` is filled.
- `check(src, typeKey, counts?) -> ok, errKey` — every accept check without changing anything (a claim runs exactly
  these); `counts = { lastHour(cid), today(cid, type) }` replaces CP.Runs' counts (the calls' cache).
- `accept(src, typeKey, opts)` / `server:acceptType` (payload a type key, `'weekly_boss'` or `{ missionType, twists
  }`). Checks in order: the leader is an officer (his own `CP.Access` error), unit leader, unit not locked, unit size,
  maintenance, the Cross-Department lock, every member an officer, then per member `CP.Alerts.inArena`
  (`err.in_arena`), active run, real call, hourly cap, daily caps (`Config.Limits.maxCompletionsDay`,
  `Config.MissionTypes[type].dailyLimit`: `err.daily_cap`, `err.member_daily_cap`, `err.type_daily_cap`,
  `err.member_type_daily_cap`), type cooldown; then `CP.Runs.capsOk` (`err.server_busy`), the boss checks and the
  twists (`checkTwists`). Only then `CP.Units.lock(unit)` (unlocked on any later failure), the ready check for units
  of 2+ (`CP.Units.readyCheck`, reply `{ pending = true }`), the draw and `CP.Runs.create`. Rate: 1 accept per 1.5 s
  per player and an in-flight guard per member (`err.busy`). `opts`: `area`, `nearCoords`, `missionCall = { id, code,
  area, staff }` (the response target is set from the unit's nearest member to the drawn start), `onDone`, `twists`.
- Weekly Boss accept: the Tactical type cooldown does not block it (accepted as `weekly_boss`; abandoning starts no type
  cooldown); the hourly cap, the Tactical server cap, the operation lock, the boss's own cooldown, department, size and
  once-per-week do. Passed to `create` as `missionType = 'tactical'`, `isBoss = true`.
- Twists: `twistOffer(key, defs)` (each card's `twists`), `twistCaps()` (`twistMax`), `checkTwists(typeKey, officers,
  raw) -> keys | nil, errKey`.
- An edited built-in is drawn under the built-in's id.

### 5.8 CP.Scaling — modules/scaling (S)
- `tierFor(n)` (first `Config.Scaling` row with `maxParticipants >= n`, else the last), `tierByName(name)` (unknown =
  the first row), `lower(a, b)`, `label(name)`, `scaleCount(base, tier)` (`round(base * tier.count)`).
- `apply(mission, tier) -> objectivesCopy` — a deep copy with every `mission.scaling` path scaled (paths start at an
  objective index, `objectives.` optional; numbers and lists of numbers; `{ path, max }` clamps).
- `combat(baseAccuracy, baseArmour, tier, run) -> accuracy, armour` — + tier, + `Config.Events.armoredArmour` with
  `armored_hostiles`, + `Config.NpcDifficulty[preset].accuracyAdd/armourAdd`; accuracy then goes through
  `CP.NpcCombat.scaleAccuracy` and is clamped to 0..100; armour is ≥ 0, not capped. A boss's accuracy goes through
  `ctx.combat` too (its armour stays the file's).
- `feel() -> { healthMult, surrenderMult, fleeMult }` for the blocks (fleeMult stretches CP.Npc's flee clock, §5.11).
  Difficulty presets change how NPCs feel, never points or cash.

### 5.9 CP.Events — modules/events (S)
- `typeOfTheDay(dayKey?)` — today's admin override first, else `rolledTypeOfTheDay` (seed `CP.U.hash(dayKey)`; nil
  when `Config.Events.typeOfTheDay` is false). `todOverride()`, `setTodOverride(choice, meta)` (a type, `'none'`, or
  `'auto'`/nil), `todDay()`: the choice lives in memory and in its `cp_audit` row (action `todOverride`, target the
  day key), read back on restart; another day's override is ignored, so it ends at the daily reset.
- `rollModifier(run)` — a random twist on top of the chosen ones with `Config.Events.modifierChance` (0 as shipped);
  deterministic per run (`hash(run.seed .. ':modifier')`); never for operations, the boss or tests; only an enabled
  twist that fits and is not on the run yet. `modifiers()` (the Today screen: label, armedOnly, enabled, points, cash).
- Twists the officers choose (`CP.Twists`, §2, holds the list and the bonus maths): `twistFits(key, def)` (Armored
  Hostiles only where a block's `armedCount` > 0, Time Crunch only with a time limit, none on the boss),
  `twistOffer(missionType, defs)` (every enabled twist that fits a mission of the pool; `some` = not all; `{}` for the
  boss), `checkTwists(raw, missionType, defs)` (`err.invalid_payload`, `err.twist_unavailable`), `fitTwists(run,
  chosen) -> kept, dropped` (nothing on tests, operations or the boss).
- `bossAvailable(src, officer) -> ok, reasonKey` — enabled, a boss day (`Config.Events.weeklyBoss.days`), no
  Cross-Department Mission (`err.operation_locked`), the boss mission present and on (`err.boss_unavailable`), and
  this week's attempt not used. Used = an unvoided `weekly_boss_kingpin` row since the reset of the week's first boss
  day (rows are written when a run ends, so a Sunday-night run ending after Monday's reset uses this week's attempt)
  whose end reason is not `real_call`, `force_recall` or `cancelled`, minus `cp_officers.boss_extra = { week, n }`.
  `bossUsage(citizenid) -> { used, extra, left, week }`, `forgetBossUsage(citizenid?)`; the cache drops on
  `admin:changed`, `row:voided`, `row:restored`.
- `bossCard(src)` (§9.4): locked by the hourly cap too; `available` = the unit may take this week's attempt; `busy`,
  `onCall`, `typeOfTheDay` (true when it is `tactical`) as on type cards; cash `CP.Cash.range('weekly_boss')` or the
  base × tier, points `CP.Scoring.P(def)` or `Config.Events.weeklyBoss.points`.

### 5.10 CP.Runs — modules/runs (the engine)

Files: `modules/runs/server.lua`, `modules/runs/client.lua`, `locales/parts/engine_b.json`; tests
`tests/engine_a_spec.lua`, `tests/engine_b_spec.lua` (client half: `tests/fixtures/engine_b/client_spec.lua`).

#### Server API
- `create(opts) -> run|nil, errKey` — `opts = { mission, locationIndex, missionType, members = { officer | src },
  leaderSrc, operationId, test, isBoss, missionCall }`. See "Creating a run" below.
- `get(runId)`, `getBySrc(src) -> run, participant` (active participants only), `all()`, `isOnMission(src)` (+ export
  `IsOnMission(src)`), `isParticipant(run, src)`, `activeSrcs(run)`, `host(run)`.
- `capsOk(missionType) -> ok, errKey` (`Config.Limits.maxConcurrentRuns` / `maxConcurrentTactical`; `weekly_boss`
  counts as Tactical; operations and tests never count).
- `cooldowns(citizenid) -> { types = { [type] = untilTs }, missions = { [id] = untilTs } }`,
  `onCooldown(citizenid, missionType, missionId) -> bool, untilTs`, `clearCooldowns(citizenid, scope, key)`.
- `completionsLastHour(citizenid)` (completed rows of the last 3600 s, no `manual_award`/`goal`),
  `completionsToday(citizenid, missionType|nil, raw)` (completed rows since `CP.Schedule.dayStart`, no
  manual_award, goal or operation rows; the day count without a type and not `raw` takes off today's extra runs,
  `cp_officers.cap_extra = { day, n }`, `extraRunsToday(citizenid)`). Both cached 10 s and dropped on a completion;
  `admin:changed { citizenid }` drops that officer's caches (`_forgetOfficer`).
- `markArrived(run, src)` (from CP.Route; also patches that participant's HUD `route = { status = 'arrived',
  distance = 0 }`), `addParticipant(run, src, opts)` (late join of a live case only, §5.46; `_newParticipant` builds
  the record for both), `removeParticipant(run, src, endReason, opts) -> rowId|nil` (`opts.keepFlag` for downed,
  `opts.silent` = no toast or result screen, `opts.notify` = a locale key toasted to the leaver).
- `endRun(run, 'completed'|'failed', endReason)`, `failRun(run, reasonKey)` (= `endRun(run, 'failed',
  'mission_failed')`), `cancelRun(run, endReason = 'cancelled', { src, reason })` (§5.39: down participants go through
  `CP.Downed.handle`, everyone else leaves as Abandoned through the normal cleanup; an operation's run is ended through
  `CP.Operations.cancel`).
- `reclassify(citizenid, runId, newEndReason)` (from CP.Calls: `real_call` → `real_call_cancelled`).
- `objectiveComplete(run, index, data) -> bool`, `dispatch(run, index, src, ev) -> ok, reason` (a server-originated
  event such as `{ type = 'cuffed' | 'shot' | 'damaged', ... }` from CP.Npc to the owning block's `onEvent`, no
  client checks), `objectiveEvent(run, index, data)` (→ `client:objective`), `send(run, event, ...)` (every active
  participant), `entityEvent(run, netId, ev)` (handed_over, impounded, removed to the owning objective).
- Points: `award(run, id, opts)`, `penalize(run, id, opts)` — `opts = { src (personal) | nil (shared), count = 1,
  weight = 0-1 }` (count × weight; weight 0 records nothing; CP.Scoring reads a line's count to two decimals).
- Stats: `noteWeaponFired(run, src)` (proof for `no_weapons_fired`), `noteStat(run, src|nil, key, n)` (citations,
  impounds, rescues, vehicles_stopped, evidence, decisions_ok/best/bad, lethal; nil src = every active participant),
  `noteArrest(run, src, netId) -> bool` (once per person per run), `notePerson(run, netId, { label?, demeanour?,
  did? })` (the people debrief; `did` ∈ walked_away, ran, drew, surrendered, feinted, cuffed, escaped, killed, each
  once; RunResult.people only for rows settled after the run ended).
- `decide(run, src, entry) -> bool` — `entry = { contact, kind, choice, verdict = 'best'|'ok'|'wrong'|'critical',
  bonusId, points, truthKey, bestChoice, facts, factLog, discoverable, knownAt, failKey, netId }`: the ledger, the
  decision stats, `noteArrest` for an Arrest graded best or ok, the personal award or penalty (points 0 = graded, no
  points); `critical` fails the run with `failKey`. `factLog` entries are kept as `{ key, text, atS }`.
- Timer: `adjustTimer(run, seconds)` (negative = time off), `pauseTimer(run, paused)`, `remaining(run)` (nil before
  In progress), `addTime(run, seconds, maxTotal)` (§5.39: only while the timer runs, total in `run.timeAdded`,
  `run.timeLimit` unchanged so `fast_finish` uses the original limit), `pauseFastClock(run)` (once; the time limit
  grows by 60 s + 20 s per held body).
- Entities: `spawnPed(run, { obj, model, coords = vec4, role, armed, weapon, accuracy, armour, health, cfg, tag, alt,
  hidden })`, `spawnVehicle(run, { obj, model, coords, role, tag, plate, alt, vehicleType })`, `spawnObject(run, {
  obj, model, coords, role, tag, frozen = true, alt })` → `entity, netId` or nil over the caps;
  `deleteEntity(run, netId)`, `entitiesFor(run, filter)`, `canSpawn(run, n, armed)`, `entityDied(run, netId,
  killerSrc)` (the single death path), `adopt(run, netId, toIndex)` / `adoptMany(run, netIds, toIndex) -> n`,
  `ownerOf(run, netId)`, `arm(run, netId) -> bool` (a hidden contact gets its weapon, armour and combat cfg once),
  `holdBodies(run, { roles, max })` / `heldBodies(run)` / `releaseBody(run, netId)` (bodies kept for Process the
  scene, FIFO past max), `isMissionPlate(plate)`, `noteExternalRemoval(netId, src, via, dist)`.
- Spawn director: `choosePoints(run, candidates, n, opts) -> points, indexes, spare`, `whenNear(run, point, range)
  -> bool, metres` (blocks use `ctx.choosePoints` / `ctx.whenNear`). Below.
- Pointer: `marker(run)`, `startMarker(run, i)`, `syncMarker(run, nowMs) -> sent`, `actionPoints(run)`. Below.
- HUD and views: `hud(run, patch)`, `hudFor(run, src, patch)` (both accept CP.Lt tokens), `view(run, src) ->
  ActiveMissionView` (§9.4), `summary(run) -> LiveRun` (§9.5).
- Test hooks (test runs only, CP.Testing): `testSkip(run)`, `testRestart(run)` (the block's `restart`, else stop,
  delete its entities, clear its state, prepare, start; clears the objective's spawn clocks and `staged`),
  `anchor(run) -> vec3, netId?` (the current objective's first point from its fields — checkpoints, points, spawns,
  npcs, targets, door, suspect, spawn, center, route, safe, scene or `run.shared.devices` — then a live entity of
  it (kept in `run.objectives[i].anchorNetId`, never custody's van or driver), then the start).

#### Creating a run
- `members` may be officer tables (§3.1) or srcs (resolved with `CP.Access.getOfficer`, then `CP.Qbx.getInfo` for
  non-police test admins). Refusals: `err.invalid_mission`, `err.invalid_location`, `err.no_members`,
  `err.member_unavailable`, `err.already_on_run` / `err.member_on_run`, `err.in_arena`, `err.server_busy`,
  `err.maintenance` (while `CP.Maintenance.active()`, every kind of run).
- The lookups during `create` may yield, so right before the run is registered (no yield in between) it re-checks
  that no member is on a run, every member is online, the caps (not tests or operations) and maintenance: two racing
  accepts never put one officer on two runs or pass the caps together. `CP.Draw.reserve`'s return is ignored (the
  draw holds a provisional reservation; a spot may have several holders).
- The modifier is rolled only for runs that are not tests, operations or the boss. Time Crunch: `timeLimit =
  round(timeLimit × (1 − Config.Events.timeCrunchCut))`.
- `run.unit = CP.Units.unitOf(leaderSrc)`, kept and unlocked when the run ends (not for test runs).
- `opts.missionCall = { id, code, area, targetS, staff }`: `rapid_response` (personal) on arrival within `targetS`,
  never for staff calls.
- Mission items are given at accept with metadata `{ cpRun = run.id, cpItem = true }`, never to an in-arena player,
  and removed by slot (ox_inventory's Search matches values only). Items not found go on an in-memory orphan list by
  citizenid, swept on player load (5 s after), 10 s after `CP.Alerts.foreignClearedAt[src]` and every 60 s. Items are
  kept back only while the player is in a routing bucket other than 0; the `crimsonArena` flag alone in bucket 0 (a
  client can write it) does not keep them, but keeps the orphan record so the sweep after the flag clears still runs.
  The load sweep and a sweep 15 s after resource start also remove any `cpItem` (mission items and
  `Config.Custody.evidenceItem`) whose `cpRun` is not live: that is what takes back items after a restart.
- `client:start` carries `timeLimit` and the drawn `location` (the mission is sent without `locations`). A start whose
  radius is at least 200 m (Manhunt's search circle) gets a local radius blip until the officer is inside or the
  first objective starts.

#### Route, objectives, timer, HUD
- The server calls `CP.Route.begin(run, src)` for every participant at accept and `CP.Route.stop(run, src)` when one
  leaves or the run ends; the client begins on `client:start` and stops when its own participant entry is `arrived`.
- The tier counts every active participant (arrived or not); `client:inProgress` and objective actions go to every
  active participant, so late arrivals run the client halves too. A leave before the start recalculates
  `expectedTier` (`client:tierChanged`); a forced test tier never changes.
- `ctx` is built once per objective (so `ctx.rng` continues); `ctx.obj`, `ctx.tier`, `ctx.state` are refreshed on
  every hook; `ctx.state` is `run.objectives[i].state`.
- `objectiveComplete`: `minSeconds` counts from the objective's start. An early call returns false; more than 1 s
  early flags `too_fast` once per objective (`CP.AntiCheat.flag`, never for tests). Completed objectives keep their
  entities until the run ends. `onTimeout` returning `'completed'` ends the run completed/completed, else
  failed/`time_limit`.
- Every run ticks in its own 1 s thread, so a block tick that waits never delays other runs; a run whose previous
  tick is still busy skips that second (one warning after 30 s).
- `ctx.hud(patch)`: `detail`, `value`, `max` go to that objective's HUD entry (`false` clears), every other key is a
  top-level patch. HUD objectives (§9.3): one entry per objective, `value`/`max`/`detail` from the block's
  `checklist`, `ctx.hud` values win, done objectives keep their last checklist. The full list is resent when it
  changes; the `run` topic is pushed at most every 2 s for progress. Timer patches `{ remaining, paused }` on start,
  adjust, pause and every 30 s. Client HUD messages clear after 8 s; the ended HUD hides 12 s after the end.
- Stage ahead (`Config.Spawning.stageAhead`, read live, missing = on): while objective i is current the tick calls
  objective i + 1's `stage(ctx, dt)` hook (with i + 1's own ctx, so what it spawns belongs to i + 1) until i + 1
  starts. `true` sets `run.objectives[i + 1].staged` (`ctx.staged` in later hooks); an error stops staging for that
  objective (`CP.warn`). A yielding `stage` sets `staging`; `StartObjective(i + 1)` waits for it up to 30 s, then
  starts unstaged. A staged entity's events (`onEntityDead`, `dispatch`, `rescale`) reach its block before it starts,
  never `onParticipantLeft` or `tick`. Used by `hostile_waves` objectives with `stage = true` (§3.3;
  `Config.Spawning.stageWakeRange` wakes their calm crew early).

#### Spawn director (Config.Spawning)
Every distance is 2D from active participants' server-side ped coords. `choosePoints` returns at most `n` (nil =
every passing one) of the block's `candidates` (vec3/vec4, `{ x, y, z }` or `{ coords, indoor, label, first }`) in
list order, their indexes, and `spare` (other passing points, the wave's sector first) for an entity whose point a game
finds bad (§5.43). A point is skipped when:
- it is closer than `minDistance` (`minDistanceIndoor` for indoor points) to a participant; after `waveDelayMax`
  seconds of a wave (`opts.wave`, clock in `run.spawning[obj]`, `opts.since` sets its start) the distance becomes
  `min(distance, hardMin)` and one `CP.warn` is printed;
- it is "behind" a participant within `activateRange`: more than `behindAngle` degrees off that participant's line to
  the scene centre (`opts.centre`, default the middle of the candidates; within 5 m of it, the way in from
  `opts.from` / the start);
- it is outside the wave's sector: the points must fit one `maxSpread`-degree sector seen from the participants near
  the centre, the sector holding `opts.placed` first, then the most points, then the earliest.
Too few good points: fewer come back, never a bad one. `Config.Spawning.enabled = false`: the first `n` as they are.
With `Config.Spawning.log`, one `CP.log` per skipped point and reason.

Hidden first (`preferHidden`): when more points pass than `n`, the block did not pass `opts.ordered`, and the caller
can yield, the director asks up to 4 nearby participants' games (`client:spawn:visible`, §5.43) about the first 32
points and waits at most `losTimeoutMs`. A point is hidden only when every asked game says exactly `false`; any
missing answer (timeout, error, busy game) means nothing is known. The rules then run again from fresh coords, and
passing points are ordered hidden first (a `first = true` candidate stays ahead: the boss's spot); of two sectors with
as many points, the one with more hidden points wins. `opts.unseen = true` (a harmless thing that must only not pop up
in sight): a point failing only the distance rule still passes when no asked game sees it; such a point never counts
toward the wait warning.

`whenNear(run, point, range)` is true when a participant is within `range` (default `activateRange`), and always
while the director is off.

#### The objective pointer (Config.Markers, drawn by §5.44)
`marker(run)` is the block's `marker(ctx)` hook (§7.1), normalised (keys as strings, coords to the centimetre, at most
32 targets, labels text or CP.Lt token strings). `false` = none; no hook, nil, or an error (then `markerOff` for that
objective) = the fallback: a pin at `anchor(run)` or, when the anchor is a live objective entity, that entity as the one
target. nil while Markers are off or no objective is active. `startMarker` rides on `client:objective {
action = 'start' }`; `syncMarker` runs after `start` and every tick and sends `client:marker` only on a change (shape
at once, positions at most every `Config.Markers.trackEvery` s; nil once). `actionPoints(run)` (CP.Route's late
partners, §5.12): the anchor, then the last sent pointer's points; empty before In progress.

#### Entities
- Every spawned entity gets the `cp` state bag `{ run, obj, role, state = 'idle', armed, cfg, place }` (§6.2). The
  server keeps its own copy in `run.entities[netId].bag` and never reads the bag back; "is this a run entity" is
  answered from `run.entities` only.
- Every new entity asks for its placement (`CP.Spawn.ask`, §5.43), written into the bag as `place`; `opts.alt` (at
  most 8) are the other points it may move to.
- Caps `Config.Limits.maxArmedAlive` / `maxEntities` are counted now (callers wait and retry, never cut counts); spawns
  still waiting for their entity count (`run.pendingSpawns`); cuffed NPCs do not count as armed; corpses count until
  deleted (`Config.Limits.corpseCleanup`). A hidden contact's `armedTruth` counts toward `maxArmedAlive`. An entity
  that appears after 3 s is deleted when it does (within 30 s, model checked).
- Vehicles use `CreateVehicleServerSetter` (`opts.vehicleType`, default `'automobile'`), falling back to
  `CreateVehicle`. Wrecks: `GetVehicleEngineHealth <= -3999` always, `GetEntityHealth <= 0` only after a positive
  value was seen (server-side health reads 0 until a client synced it). An entity missing on 2 ticks goes through
  `entityDied` (killer nil). Ped deaths come from CP.Npc.
- Plates: every mission vehicle gets a `Config.Custody.plates` plate from its own random stream (never the run seed),
  rerolled up to 5 times when `CP.Qbx.plateOwned` says a player owns it; a plate a mission asks for is kept only when
  it fits that pattern and no player owns it.
- External removal (remembered 15 s): a vanished vehicle whose last sample had engine and body above 0 was removed,
  not wrecked: `{ type = 'removed' }` to its objective; by a participant → flag `sc_impound` and fail
  (`reason.vehicle_removed`); by anyone else or unknown → everyone leaves with `vehicle_removed_external`
  (abandoned, no points, cash or cooldown) and the audit `vehicleRemoved`.
- Host: an offline host passes to the next in join order; a host silent for 15 s (`GetPlayerLastMsg`) hands over only
  to a responsive participant.

#### Events, telemetry, access
- `server:objective` (runId, index, evidence): active participant, run in progress, integer index; evidence sanitised
  (≤ 32 keys, depth ≤ 3, strings ≤ 256). Server-only types (`cuffed`, `decide`, `action`, `removed`, `handed_over`,
  `impounded`, `shot`, `damaged`, and CP.Opponents' `opp_*`, §5.45) from a client are refused and flag
  `unexpected_event`. `CP.AntiCheat.checkEvent` sees every other event (a throw drops it); then `CP.Access.recheck`
  (may yield; everything is checked again after it) and the block's `onEvent`. Block rejections are logged, never
  flagged; events for unknown runs or from non-participants are only logged.
- `server:abandon` (runId) → `removeParticipant(run, src, 'quit')`.
- `server:telemetry` (runId, kind, data), in-arena senders ignored: `vehicle` (driver of a non-mission vehicle, at most
  every 3 s, lowest engine/body kept); `ped_hit` (a non-mission ped within 30 m of a sender in a vehicle, once per ped,
  at most 10 per participant → `pedestrian_hit`); `lights_siren` (once per participant on `quietPatrol` missions —
  Beat Patrol, Business Check — in a vehicle once in progress); `weapon_fired` (once → `run.stats.weaponsFired`, `p.firedWeapon`).
- `CP.Access.onLost`: `off_duty` is re-verified with `CP.Access.recheck(src, p.job)` before the removal; `job_change`
  and `suspended` are trusted; any other reason counts as `job_change`.
- Loops: the 1 s tick per run; `Config.AntiCheat.jobRecheck`; corpse cleanup; the start timeout per participant; the
  60 s cooldown maintenance and orphan sweep. `playerDropped` and character unload → `disconnected`; resource stop →
  delete all entities, no rows.

#### Leaving and ending (§4.3)
- Everything that must not race (status, cooldowns, host, rescale, flags, route) happens before the first yield; then
  the row, the payment and the hooks.
- A participant who is down at `endRun` (`CP.Qbx.isDowned`, not in the arena) leaves first through `CP.Downed.handle`
  (Failed, `downed`). `removeParticipant` counts `run.stats.downs` for `downed`, calls `onParticipantLeft` for the
  current objective and `rescale` for every objective not done.
- The last participant out ends the run; `run.endState` and `CP.Operations.onRunEnded` get `'failed'` when that last
  result was failed (downed/disconnected), else `'abandoned'`.
- Operation runs start cooldowns like any run. Weekly Boss: never a type cooldown; the mission cooldown and the week's
  attempt apply.
- `reclassify` replaces only a `real_call` end reason, sets `state` and the JSON `endReason`, applies the new reason's
  cooldowns from now, drops the pay tier if the run is still running, and works from the row alone once the run is
  gone; false when nothing matched.

#### Rows (cp_mission_runs)
- One insert per participant with every column (nil as `NULL` literals): `season_id`, `department` (the active job's
  department at the end when it still is one, else the accept-time one), `participants` (active at the end plus the
  row's officer), `departments_n`, `tier` (pay tier), `modifier`, `mission_version`, `location_label`,
  `location_index`, `duration_s`, the stat columns (arrests, citations, impounds, rescues, vehicles_stopped,
  evidence, decisions_*, lethal), `medal` (1-3 from the medal_* awards), `mission_call_id`, `response_s`,
  `penalty_points` (positive sum), `bonus_points`, `cash_multiplier` (mTier × mMod, 2 decimals) and `breakdown` =
  RunResult JSON (§9.6). Only completed rows are summed by badges and stat goals.
- Presence: completed/failed results of runs that ever had 2+ participants are checked with
  `CP.AntiCheat.presenceOk`; a failure flags `presence`.
- Flagged rows keep their computed points and cash (an approval releases them); `cash_status = 'held'` only for
  completed flagged rows. `CP.Cash.pay` runs for completed unflagged rows with an amount; the final status is written
  into the breakdown and the result. `CP.Scoring.onRowCounted` for unflagged completed/failed rows,
  `CP.Goals.onRunCompleted` for unflagged completed rows, `CP.Draw.recordLast` for completed and abandoned rows.
- Test runs compute the RunResult (would-have points and cash) and write nothing.
- RunResult extras: `failReason`, `cash.paid`, decisions, people, stats (lethal left out), missionCall, progress
  (CP.Scoring's `row:settled` listener), items. `Config.Decisions.debrief = false` sends the officer's card without
  decisions and people and keeps them out of the officer's own history; the stored breakdown keeps them.
- `view` adds `me`, `isBoss`, `operationId`, `startIn` (accepted runs, not arrived), `intel` (`run.shared.intel`),
  `missionCall = { code, targetS, arrivedS }` and `contact` (CP.Custody.view).

#### Cooldowns
Kept in memory per citizenid, rebuilt from rows of the last `max(abandonCooldown, largest mission cooldown)` seconds on
the first `cooldowns()` call and on player load; voided rows count, rows at or before a `cp_officers.cooldown_clears`
marker (`all`, `type[<type>]`, `mission[<id>]`) do not, so a clear survives a restart. An online map (`citizenid <->
src`, from the Qbox load/unload listeners, `playerDropped`, the accept re-check and the start sweep) decides which
entries the 60 s maintenance prunes; `CP.Qbx.getByCitizenId` is called once only for a citizen the map has never seen.

#### Hooks (CP.Hooks, shared/init.lua, both sides)
Listeners run in the caller's thread, in the order added, each in pcall.

| Hook | Arguments | Fired by | May yield |
|---|---|---|---|
| run:created | run | CP.Runs.create | no |
| run:arrived | run, src, isFirst | markArrived (after In progress on the first arrival) | no |
| run:inProgress | run | the engine, after every block's prepare | no |
| participant:left | run, src, endReason | removeParticipant | no |
| row:settled | run, p, rowId, row, result | after cash, XP and goals, before client:runEnded; listeners may add to result | yes |
| run:ended | run, state, endReason | after every row | yes |
| row:approved / row:voided | rowId | CP.Scoring.onRowApproved / onRowVoided | yes |
| row:forfeited | rowId | CP.Cash.forfeit and the forfeiture job | yes |
| arena:exited | src | CP.Alerts' 1 s reconcile when inArena turns false | no |
| xp:levelUp | citizenid, src or nil, oldLevel, newLevel | CP.Scoring | no |
| goal:completed | citizenid, goalId, period (`daily:<day>` / `weekly:<week>`) | CP.Goals, after the goal row | yes |
| season:ended | seasonId, { champion, top10 } | CP.Challenge | yes |
| home:extras | citizenid, src, extras | CP.Scoring homeData | no |
| officer:loaded | src | CP.Cash, after the pending payments | yes |
| tablet:closed | src | CP.Tablet `server:tabletClosed` | no |

#### Client
- `CP.Runs.current() -> { id, mission, location, locationIndex, seed, isHost, test, state, tier, payTier, modifier,
  objectiveIndex } | nil`, `report(index, evidence)` (adds `coords` and `time`), `telemetry(kind, data)`,
  `getEntity(netId, timeoutMs)`, `control(entity, timeoutMs)` (host only), `hudDetail(text|nil)`,
  `adoptedBy(netId)`.
- Runs the block client halves: `prepare`, `start`, `update`, `stop`, `hostChanged` (§7.2); an `adopt` action calls
  the new objective's `adopt(ctx, netId, from)` and the old one's `release(ctx, netId)`.
- HUD patches and objective updates are resolved with `CP.Locale.resolveAll` before the NUI.
- NUI client action `logResult { point, choice }` → `report(current, { type = 'log', ... })` (Business Check).
- Telemetry loops only while on a run: ped hits by the player's vehicle, lights/siren, weapon fired, current vehicle.

### 5.11 CP.Npc — modules/npc (shared NPC behaviour for blocks)
Files: `modules/npc/{server,client}.lua` (the headers are the full API reference), `locales/parts/npc.json`; tests
`tests/npc_spec.lua` with the client halves `tests/fixtures/npc/client_check.lua` and `target_check.lua`.

Server:
- `setState(run, netId, state, extra) -> bool` — states `idle`, `hostile`, `fleeing`, `surrendered`, `cuffed`, `dead`,
  `restrained`, `freed`, `safe`, `driving`, `stopped`, `contacted`, `escorted`, `seated`, `released`, `handed_over`,
  `impounded`. The bag is replaced as a whole; `extra.cfg` merges into `bag.cfg`; `extra.task = { action, args }` is a
  one-off host task identified by `bag.taskSeq`; `run`, `obj`, `state`, `seq`, `taskSeq` and `place` cannot be written
  through `extra`; a state change drops a previous task; `seq` grows on every write; the same state without extra is a
  no-op. Refused for an unknown state, a bad or foreign net id, an ended run, a missing entity. A hidden contact is
  refused `hostile` until `CP.Runs.arm` armed it.
- `getState(netId)`, `isNeutralised(netId)` (dead, cuffed, escorted, seated, handed_over) — from the server record
  (seeded from `run.entities[netId].bag`, mirrored back), never from the replicated bag. `adopt(netId, obj)`.
- `setPlace(run, netId, place|nil) -> bool` — CP.Spawn's placement ask into the bag or out of it (§6.2), no `seq`
  change, nothing re-tasked.
- `rollSurrender(run, netId, chance)` — one deterministic stream per run, each ped rolled once (repeated calls return
  the first result); a chance above 1 is a percentage.
- `enableCuff(run, netId, opts)` — `bag.cuff = { label (≤ 64, default npc.cuff), duration (500–60000 ms, 5000),
  maxDistance (1–10 m, 3.0) }`; participants get ox_target "Cuff suspect" while `surrendered`. `server:npcCuff` (runId,
  netId; 3 per 2 s) is validated: run in progress, active arrived officer not in the arena, a live surrendered cuffable
  ped of this run within `maxDistance + 0.5`, and in reach (`maxDistance + 1.5`) for at least `duration − 2 s`
  (sampled every second); `Config.Custody.handcuffsItem` needs that item (never used or taken,
  `err.npc_no_handcuffs`). Then `setState('cuffed')` and `{ type = 'cuffed', netId }` to the block (a refusing block
  does not revert it). Refusals toast `err.npc_*`.
- Deaths: a 1 s check over every live run's peds; health ≤ 0 or a vanished entity whose record remains is a death
  (once; `deleteEntity` is not). Killer: `GetPedSourceOfDeath` → a player's ped or the killing vehicle's driver (an NPC
  = no player), else the last player weapon hit within 5 s; an in-arena killer is dropped. `CP.AntiCheat.onNpcKilled`
  (outside killers) runs before `CP.Runs.entityDied` (which may end the run). `onDeath(fn(run, netId, killerSrc,
  killerIsParticipant))`. CP.Npc never fails a run itself: the block's `onEntityDead` decides (with a 3 s grace after a
  surrender). Participant always means an active one. A participant killing a suspect-role ped adds the `lethal` stat.
- `weaponDamageEvent`: the shooter is the sender, except a parent NPC the sender owns (nobody); a parent naming a
  vehicle is never a shot; at most 32 hits; returns at once when already cancelled; in-arena senders ignored.
  - A participant shooting a `surrendered`/`cuffed`/`restrained` ped → `shot_surrendered` (personal, once per shooter and
    ped per 2 s, never within 3 s of the surrender, any weapon but unarmed/melee/vehicle/fall; a toast with
    `Config.Scoring.common.shotSurrendered`) and `{ type = 'shot', netId, src }` to the block.
  - A participant's gun hit or gun kill on a mission ped → `CP.Runs.noteWeaponFired`.
  - excessive_force: a participant's melee or taser hit on a cuffed, escorted, seated or contacted ped, the health-drop
    fallback, and validated `stun_hit` telemetry (a taser there is force, not shot_surrendered; once per person per
    10 s, through CP.Custody).
  - The host-owned gap (no event for damage to one's own entities): a 1 s health + armour poll attributes a drop with no
    event in the last 2 s via `GetPedSourceOfDamage` (an NPC, a driver, or a player only when he owns the ped); a drop
    with no source is ignored.
  - `onDamaged(fn(run, netId, attackerSrc))` for `hostage` peds only, one report per ped and attacker per second;
    `{ type = 'damaged' }` to the block only for a participant attacker.
- A second listener (`Config.NpcCombat.cancelLethalHeadshots`): `CancelEvent()` for a `willKill` hit from an armed
  living mission ped on active participants in bucket 0, not in the arena, whose synced health is at least
  `CP.NpcCombat.lethalCancelAbove()` (0.75) of the part above 100 (so the shot that finishes a hurt officer is never
  dropped). The only `CancelEvent` of the resource (Crimson-Arena rule 11).
- Dwell sampler for police actions: `watch(run, netId, src, range)`, `inReachSince(run, netId, src)`, `unwatch` (a
  sample out of range restarts it). `stunMatches(netId, windowMs)`, `runOf(netId)`, `stunProof(netId)` (a ragdoll the
  server saw within 1 s; a state change is no proof; true with `stunNeedsProof = 'off'`), `stunCheck(run, src, netId)`
  (a block's `stunned` report through `CP.AntiCheat.stunReport`, §5.26).
- Flee clock (Config.Flee; GTA AI has no stamina): the 1 s watcher adds every ped's time fleeing on foot to
  `rec.fleeSpent` (kept across flips; nothing counts in a vehicle). Gait `sprint` until sprintSeconds, `jog`, `walk`,
  then `spent`, each × (1 ± jitter, one roll per ped from the seed) × `CP.Scaling.feel().fleeMult`; no participant
  within recoverRange for recoverSeconds resets it; `armedTire = false` keeps armed peds fresh; `enabled = false` = no
  tiring. A gait change is written as bag key `gait` in the same `fleeing` state (no re-task). `gaitOf(netId)`,
  `fleeClock(netId)`, `wornOut(netId, near) -> bool, task|nil` (spent, `Config.Flee.exhausted` not `'walk'`, within
  `giveUpRange`; task nil = kneel, or `{ action = 'handsUp' }`; the block checks the ped's state, §3.3).
- `playerDropped` forgets that player's reach samples and shot windows.

Client (the host runs the AI; every participant sees targets):
- `apply(entity, cfg)` — never heals on a new host (health only on an untouched ped, armour only when 0); max health and
  weapons ensured; `SetPedDropsWeaponsWhenDead(false)`; calm states disarmed and in `CRIMSONPOLICE_NEUTRAL`, else
  `cfg.group`. Hostile: flee attributes off, combat attributes 17 off / 58 on, no ragdoll from player impact (ragdoll
  from weapons stays: stuns), blocked non-temporary events, `SetPedDiesWhenInjured(true)`. Config.NpcCombat (§5.42):
  the weapon via `CP.NpcCombat.weapon`, ammo, accuracy ≤ accuracyMax, and for an armed ped `SetPedShootRate`,
  `SetPedFiringPattern` (again after each `TaskCombatPed`), ability ≤ abilityMax, attributes 27 and 24 off, 49 on, with
  noCharge 13 and 50 off.
- Relationship groups: HOSTILE hates PLAYER (5), 0 to itself, 3 to NEUTRAL and common ambient/gang groups (incl.
  sc-npcpolice's NPCCALL_HOSTILE / NPCCALL_RIVAL); NEUTRAL 3 to everything; PLAYER's own relations are never set.
  "Hostile only to participants" is enforced by targeting (combat on participants only, no guard task).
- `task(entity, action, args)`: `combat`, `flee` (from participants or along points, at the bag's gait), `handsUp`,
  `kneel`, `cuffed`, `follow`, `cower`, `wander`, `enterVehicle`, `driveTo`, `driveRoute`. Speeds are m/s (`kmh`
  accepted); a numeric `drivingStyle` wins over the name (`careful` 786603, `normal` 786475, `fast` 786492, `reckless`
  787004). Routes start at `args.startIndex` or the nearest point ahead; a waypoint is reached within `max(12 m, 1.2 ×
  speed, stopRange + 4)` (2.5 m on foot) or when passed close by; a flee route ends in `TaskSmartFleePed`.
- The host's AI loop (500 ms while it manages a ped): retargets combat every 3 s (switching when another participant
  is 40 % closer); with nobody a hostile stands still (never `TaskGuardCurrentPosition`, which attacks bystanders);
  steps routes, re-tasks stuck peds, keeps poses playing. A managed task ends on a state change or leaving the vehicle.
  Identical pose/combat tasks are ignored, movement tasks debounced 1.5 s.
- `cp` bag handler: waits one frame, applies cfg once per handle after `CP.Runs.control`, re-tasks only on a state or
  task change (surrendered → hands up then kneel; cuffed → pose and freeze; fleeing → flee; hostile → combat); a pose
  release unfreezes only when `CP.Spawn.holds(ped)` is false (§5.43). On `client:hostChanged` to this client every ped
  is re-applied. Every client marks every ped with a cp bag `SetPedDropsWeaponsWhenDead(false)` + `SetPedMoney(0)`
  (OneSync may move a dying ped to anyone).
- The combat governor (every participant's game, 1 s while on a run): applies the combat caps to each armed mission ped
  it owns, once per handle and `seq`, and holds a calm `idle` person without `contact` (a raid's staged crew) calm
  (`SetBlockingOfNonTemporaryEvents`, flee attributes 0).
- Tired runners: the host runs each foot leg at the gait's move blend ratio (sprint 3.0, jog 2.0, walk/spent 1.0) and
  re-gives it on a gait change; with no route left, 40 m navmesh legs straight away from the nearest participant to a
  `GetSafeCoordForPed` point (then ±60°, ±90°, then `TaskSmartFleePed`); stuck twice → `TaskSmartFleePed`. A runner
  standing still on a game that does not run his AI gets a flee task again from it. The pacer (every game, `Wait(0)`
  while it owns one) holds each owned tired runner to his gait every frame (`SetPedMaxMoveBlendRatio`,
  `SetPedMoveRateOverride` jogRate/walkRate, clip sets `move_m@JOG@` / `move_injured_generic` with `windedClipset`),
  and lets go in the same frame when he is no longer tired.
- "Cuff suspect": global ped options `crimson-police:cuff` and up to 8 `crimson-police:cuff:<n>` for other labels
  (ox_target labels are static); canInteract checks the ped's run, state, label, distance, on foot, alive, not in the
  arena. The bar is cancelled when the suspect stops being surrendered, moves out of reach + 1 m, or Crimson-Arena
  places the player. The option set (with the contact, custody and seat options) exists only while on a run (added
  one frame after `client:start`, removed after `client:runEnded` once the eye menu is closed).
- `nearestParticipant(coords)`. The run's end and resource stop release the animation dictionaries and clip sets.
  `client:runEnded` of another run only drops its cached participant list.

### 5.12 CP.Route — modules/route (Hard rule 17)
Files for §5.12–§5.15: `modules/route/{server,client}.lua`, `modules/calls/server.lua`, `modules/alerts/server.lua`,
`modules/downed/{server,client}.lua`, `locales/parts/safety.json`; tests `tests/safety_spec.lua`. Only the numbers
come from `Config.Route` / `Calls` / `Alerts` / `Downed`, read at call time. Their events are in the table below.

Server: `begin(run, src)`, `stop(run, src)`, `status(run, src) -> { status, secondsLeft, recalcsLeft, distance,
required }` (`'off'` only while the warning is shown; `distance` is the straight line, the HUD's the polyline left),
`requiredFor(run)`.
- Arrival: every 1 s, the ped within `location.start.radius` of the start (2D) → `CP.Runs.markArrived` in its own
  thread (then `CP.Alerts.set`, idempotent); the arrived state is kept. For Manhunt, when objective 1 is a
  `search_area`, the larger of the start and its starting circle counts. The tick also begins the route for any active
  participant without one (a missed `begin` cannot skip rule 17).
- Reports (`server:routeStatus`) count only for the sender's active run, with finite metres ≥ 0 and coords within
  `max(maxDeviation, 150 m)` of the server ped. Off route starts at the first report above `maxDeviation`, or
  `reportTimeout` s after the last good report (the first report has `reportTimeout` from `begin`); the warning comes
  after `warnAfter` s off and every second with the seconds left; the run is abandoned `off_route` after
  `abandonAfter` s in one stretch. A good report ends the stretch and withdraws the warning. The tablet's view is
  pushed when the warning appears, goes, and after a granted recalculation. Drift check per `Config.Route`.
- Recalculate (`server:recalcRoute`, ≤ `maxRecalcs`) ends the off stretch and gives a fresh `reportTimeout`; the drift
  reference is not reset.
- `Config.Route.required` (shipped true) is locked at accept as `run.routeRequired` (sent in `client:start`; copied to
  the view's `route.required`). `requiredFor(run)`: the locked value, else a test run true, a live crime
  `Config.LiveCrime.requireRoute` (shipped false), every other run `Config.Route.required`. With false the reports,
  Recalculate and arrival stay, but no warning, countdown, drift check or `off_route` end. Late joiners begin with the
  locked value. Tests with `useStartRoute = false`: only the arrival check.
- First contact (`Config.RealSuspects.routeEnds = 'first_contact'`): in a real-suspect case a participant also arrives
  when `CP.Opponents.nearAny(run, coords, contactRange)`.
- Late partners (`Config.Route.lateArriveRange`, 150 m, 0 = off): once the run is in progress a participant who has not
  arrived switches once to mode `'action'` (no warning, reports, drift or off_route; Recalculate refused,
  `err.route_action`), gets `client:routeStatus` and a `run` push, and arrives inside the start circle or within range
  of `CP.Runs.actionPoints(run)`. `CP.Runs.extendStart(run, src, Config.Route.followActionSeconds)` (300) moves his
  start deadline to now + that, never earlier.

Client: `begin(runId, startCoords, { startRoute, radius })` (waypoint and GPS sampling every `Config.Route.sampleEvery`
m from a temporary route blip, slot 1 then 0; no route within 5 s → the straight line and `route.no_gps`; also started
1 s after `client:start` as a fallback), `recalculate()`, `stop()` (never touches the HUD; removes the waypoint only
while it points at our start), reports every `Config.Route.reportEvery` s, `current() -> { runId, arrived, routeOn,
action }`, `follow(runId, dropStart, secondsLeft)` (on the `'action'` status: stops sampling, HUD route `{ status =
'action', secondsLeft }` shown from 120 s; `dropStart` (CP.Markers `leads`) removes the start pin and waypoint so the
objective line is his one line). Client actions `setGps` (re-sets the waypoint) → `{ runId }`, `recalcRoute` →
`{ recalcsLeft }` or `err.route_inactive|route_arrived|route_disabled|route_no_recalcs|busy|timeout`. The named start pin
(`Config.Markers.startBlip`, look `kinds.start`) lives from `begin` to arrival; its blip route is on while sampled and
afterwards only while our waypoint is gone; `startBlip = false`: the pin exists only while sampled.

| Event | Direction | Args | Notes |
|---|---|---|---|
| `server:routeStatus` | C → S | runId, metres, coords | plain; ≥ 0.9 s apart per player |
| `server:recalcRoute` | C → S | runId | plain; 1 per 2 s; always answered with `client:routeRecalc` |
| `server:pickupDone` | C → S | runId, ok? | plain; 2 per 5 s (downed) |
| `client:routeWarning` | S → C | runId, secondsLeft \| nil | every second while shown; nil = withdrawn |
| `client:routeRecalc` | S → C | runId, ok, recalcsLeft | |
| `client:routeStatus` | S → C | runId, RouteStatus | on arrival and on the switch to `'action'` |
| `client:pickup` | S → C | runId, dropOff | |
| `client:pickupCancel` | S → C | runId | a cancel after `client:pickup`: fade back in, never teleport |
| `client:requestEMS` | S → C | runId | |
| `client:downedEnded` | S → C | runId, reason | once, whenever a downed entry leaves the pending stages |

### 5.13 CP.Calls — modules/calls (Hard rule 15)
- `isOnCall(src, { except })` — a live real-call responding entry (`Config.Calls.respondingExpiry`; each re-checked in
  mdt_dispatch at most every 10 s, may yield); `except` ignores entries matching an `exemptFor` set.
- `exemptFor(run) -> { exact, prefixes }` — the case's own call (`run.live.dispatchId`) and `'<prefix><src>_'` for
  every participant and suspect with each `Config.Calls.ownRunCallPrefixes` entry plus `shots_`.
- Classifying a mark (`CP.Dispatch.onResponding`): NPC prefix (no lookup) → `lookupActiveCall` (only a hit counts) →
  NPC prefix on the canonical id → own-run prefixes (any participant of the sender's run, also partners who left) →
  in a real-suspect case `exemptFor(run)` → a real call: the run ends `real_call` (a sender not on a run is just
  recorded). The map is keyed by the canonical id with the raw form as alias.
- Dodge rule: an un-mark within `Config.Calls.dodgeWindow` of the free abandon (the same call, or one never marked;
  a dispatcher detach looks the same) → `CP.Runs.reclassify(..., 'real_call_cancelled')`. An un-mark that arrives
  during the lookup or while the row is written is applied once the row exists.
- Every free abandon is audited (`free_abandon`, flags, with the count of the last 24 h); an admin's **Treat as a
  normal abandon** (§5.39) reclassifies a saved `real_call` row of the last 24 h.

### 5.14 CP.Alerts — modules/alerts (Hard rule 16; the only writer of the crimsonArena bag)
The full rule set is the Crimson-Arena section of `docs/INTEGRATIONS.md` (rules 1–3, 9).
- `set(src, run)` → `Player(src).state:set('crimsonArena', { active = true, source = 'crimson-police' }, true)`;
  refused in a routing bucket ≠ 0, over any value that is not ours, and in a real-suspect case while
  `Config.RealSuspects.officerAlerts` is not `'silenced'` (`alertsGoOut(run)`; with `'silenced'` only active
  participants, never a suspect). `releaseRun(run)` clears our flags once a run became such a case.
- `clear(src, { force })` — only our value; ignored while CP.Downed holds it (`hold(src, on)`) unless forced.
  `forget(src)` drops our intent, hold, orphan timer and queued re-assert without touching the bag (rule 1).
- `has(src)`, `foreignFlag(src)` (an active value whose source is not ours), `inArena(src)` (`foreignFlag` or bucket
  ≠ 0: the gate every module uses), `onInArena(fn(src, run))`, `foreignClearedAt[src]` (a table, recorded from the
  change handler's old value, so an exit counts even when we never saw the foreign value).
- An in-arena participant is removed here (`removeParticipant(run, src, 'quit', { notify = 'run.left_for_arena' })`
  after `forget`, `CP.Route.stop`, `CP.Downed.cancel`) or by the engine's own re-check, whichever runs first. Our flag
  is re-asserted after a foreign wipe. An intent whose run no longer lists the player is removed after 3 s; a value of
  ours left on a player who moved bucket is removed once he is back in bucket 0 with no intent.
- The 1 s reconcile fires `arena:exited (src)` once when `inArena` turns false.
- Backstop (not for runs where `alertsGoOut` is true): shots fired within `Config.Alerts.backstopRadius` (3D, of the
  start or `CP.Runs.anchor`) of a flagged or arrived participant, or a flagged person down/dead → clear the call after
  `Config.Alerts.backstopDelay` s (repeated when an earlier clear may have run before the call existed).
- Start: removes leftover flags of ours from every player; stop: clears all.

### 5.15 CP.Downed — modules/downed (Hard rule 18)
- Server: every `Config.Downed.checkEvery` s, and at once on `onMetaDataChange` (`isdead` / `inlaststand`), active
  participants with `CP.Qbx.isDowned` leave through `removeParticipant(run, src, reasonFor(run), { keepFlag = true })`
  (a down is counted once). Then, once per down (cancelled on drop/unload): no EMS (`doctorCount() == 0`) → after
  `Config.Downed.pickupDelay` s EMS is checked again, then `client:pickup (runId, dropOff)`, the revive 1.5 s later
  (`CP.Ambulance.revive`), the flag removed on `server:pickupDone` or 30 s after; EMS on duty → `CP.Alerts.clear` then
  one `client:requestEMS` — except when our flag was off and `inlaststand` was true (sc-ambulance sends its own alert).
- `handle(run, src) -> bool` *(hook, from CP.Runs.endRun)*: holds the flag and removes the participant before anything
  yields, then the follow-up in its own thread; false when not active, in the arena, or already past.
  `cancel(src, reason)`, `isPending(src)`. A down that left a run with nobody active and still open after 5 s ends it
  `failed`/`mission_failed`.
- `reasonFor(run)`: `downed`, or in a real-suspect case with `Config.RealSuspects.downed ~= 'failed'` (shipped
  `'keep_earned'`) `downed_case` (live officer) / `downed_kept` (volunteer-suspect officer) (§4.3); those cases wait
  `Config.RealSuspects.downedPickupDelay` (400 s, sc-ambulance's DeathTime).
- Every way an entry leaves the pending stages (done, gave up, timeout, every cancel reason, the EMS hand-over) sends
  `client:downedEnded` once.
- Client: `client:pickup` → fade out, overlay "Picked up by an NPC unit", wait up to 20 s for the revive (revived =
  both metadata false and the ped alive; no metadata after a logout is never revived: abort, no teleport), move to the
  drop-off, fade in; `server:pickupDone` goes first and once. `client:requestEMS` → `CP.Ambulance.sendEMSRequest()`. The
  client tracks its own fade and overlay; `client:downedEnded` / `client:pickupCancel` stop a running pick-up or undo
  what is left, and `restore(why)` is the same safety net (a no-op while a pick-up runs; CP.Runs calls it at every
  cleanup). The pick-up thread always clears `busy()` and restores the screen, even when its abort fails.

### 5.16 CP.Units — modules/units
Files for §5.16–§5.17: `modules/{units,operations}/{server,client}.lua`, `locales/parts/teams.json`, web
`officer/screens/Unit.tsx`, `supervisor/screens/CrossDept.tsx`, `supervisor/components/OperationPanel.tsx` (props `{
scope: 'sup' | 'admin' }`, never wrapped in `<Screen>`), `officer/components/ReadyCheckBanner.tsx`, `types/teams.ts`
(every view shape), `mocks/teams.mock.ts` (`?teams=leader|member|solo|invites|locked|lockedoff|long|full`,
`?op=joining|running|waiting|none|cooldown|empty|fresh`, `&lua=1`); tests `tests/teams_spec.lua` (its own database
`<run database>_teams`). Both screens normalise lists first (Lua sends `{}` and drops nil keys).

Units live in memory only (a restart drops them, as it drops runs).
- `unitOf(src) -> { id, leader, members = { src }, invites = { [src] = expiresAt }, locked } | nil`, `members(src)`
  (solo `{ src }`), `isLeader(src)`, `view(src)`, `remove(src)` (never touches runs; called on drop, unload and
  `CP.Access.onLost`; cancels invites to that player).
- Forming unit = the first inviter plus pending invites; it dissolves when its last invite expires or is declined,
  and at `lock`. Any member may invite (`Config.Units.invitePolicy = 'leader'`: only the leader,
  `err.unit_invite_leader_only`, view `unit.blocked_policy`); the cap is `members + open invites <
  Config.Limits.maxUnitSize`. Invites last 120 s, one per (unit, target); joining drops the officer's other invites;
  accepting while in another unlocked unit moves him. Inviters and targets must be on-duty officers, not on a run, not
  in the arena (`err.in_arena`), not in a full or locked unit. The invitee gets one `unit` push with `invited = true`
  and a toast.
- Leader succession: `members` is in join order; when the leader leaves `members[1]` leads; one member left dissolves
  the unit.
- `lock(unit)` (withdraws pending invites), `unlock(unit|id)` *(hook: at run end)* — ignored while a member is still
  on a normal run (no operation, no test) or a ready check is pending; a unit locked 30 s with nobody on a normal run
  is unlocked by the 2 s sweep.
- `server:unitLeave` while locked and on a normal run → `removeParticipant(run, src, 'quit')` first; operation and
  test runs are left alone. A player who no longer qualifies may still leave.
- Leader controls (refused with `err.unit_locked` once a type is accepted): `kick(src, target)` (no cooldowns; that
  unit cannot invite him for `Config.Units.kickReinvite` s, `err.unit_kicked_recently`), `promote(src, target)`,
  `disband(src)`, `cancelInvite(src, target)` (leader or inviter).
- `readyCheck(unit, typeKey, onReady, onCancel, extra?) -> started` — from `CP.Draw.accept` after the lock for units of
  2+ (false = no check needed). The leader's accept is his answer; every other member gets `client:readyCheck` with the
  type and `extra.twists`, never the mission. All Ready → `onReady` once. A decline, the timeout
  (`Config.Units.readyTimeout`), a member leaving, off duty, disconnecting, in the arena or on a real call →
  `onCancel(reasonKey, srcs)` (`err.unit_ready_declined|timeout|cancelled`, toasts name who did not answer); nobody
  gets a cooldown. A second check while one is pending → `onCancel('err.busy')`. The last Ready re-checks the arena.
- `lastPartners(src)` (the online officers of his last ended non-test run, 900 s), distance bands
  (`Config.Units.nearbyBands`, server coords).
- UnitView extras: `me`, `maxSize`, `inviteTtl`, `canInvite`, `inviteBlocked`, `onRun`, `unit.canManage`,
  `unit.readyCheck`, `unit.pending`, members' `avatar` and `level`, `invitable[].distanceBand` / `lastPartner`,
  `pendingSent`, `sizeFit = { [type] = { now, plusOne } }` (pool counts only), `operation` (`officerCard`).
- Full admin control (§5.39): `adminList()`, `adminGet(unitId)`, `adminRemove(unitId, src)`, `adminDisband(unitId)` —
  refused while locked (`err.live_unit_locked`), in a ready check (`err.live_unit_ready_check`) or with a member on a
  run (`err.live_unit_on_run`).

| Kind | Name | Payload → reply |
|---|---|---|
| action | `server:unitInvite` | `targetSrc` or `{ targetSrc }` → `{ unitId, expiresIn }` |
| action | `server:unitRespond` | `{ accepted, unitId }` or a boolean (newest invite) → `{ unitId, accepted }` |
| action | `server:unitLeave` | → `{ left, abandoned }` |
| callback | `getUnit` | → UnitView |
| action | `server:unitKick` / `server:unitPromote` | `{ targetSrc }` → `{ kicked }` / `{ leader }` |
| action | `server:unitDisband` | → `{ disbanded }` |
| action | `server:unitCancelInvite` | `{ targetSrc }` → `{ cancelled }` |
| action | `server:unitReady` | `{ accepted }` or a boolean → `{ accepted }` (the key mapping sends it without a reply id) |
| client event | `client:readyCheck` | `{ typeKey, typeLabel, expiresIn, leaderName, twists }` or nil to clear |
| key mapping | `crimsonpolice_ready` | `Config.Tablet.readyKey`: answers Ready |
| push | `unit` | `{ unitId|false, invited?, readyCheck? }` to members and invitees; `board` to members |

### 5.17 CP.Operations — modules/operations (Cross-Department Missions)
- `active()`, `isLocked()` (joining, running, waiting), `view`, `boardCard(src)`, `officerCard(src)`,
  `cooldownLeft()`, `eligible(def)` (published and enabled, `departments` empty, `maxOfficers >= 2`, never the boss).
- `launch(src, missionId)` — `Config.CrossDept.enabled ~= false`, no active operation, the cooldown over (counted from
  the last persisted `created_at`; an admin may skip it with `{ skipCooldown = true, reason }`, audited
  `opLaunchSkipCooldown`), an eligible mission, not during maintenance. `launched_by` = the actor's citizenid.
- Joining: `join(src, opId)` re-checks the state after the checks that may yield, so two joins never pass the cap
  together. Minimum to start = max(`Config.CrossDept.minParticipants`, the mission's `minOfficers`); maximum =
  `Config.CrossDept.maxParticipants`. Waitlist (`Config.CrossDept.waitlist`, default true): a full operation queues the
  officer; a place freed before the start goes to the first on it, re-checked like a join; the list closes at the
  start. `leave(src)` before the start only (`err.op_leave_started`); `removeJoiner(src, target, reason)`
  (launchCrossDept, before the start, `err.op_remove_started`, audited).
- `startNow(src)` — whoever opened the current window, any admin, or anyone with the permission when that person is
  offline. At the window's end the run starts by itself with enough joiners, else `waiting` (`not_enough`); a manual
  start that fails keeps the window open. At start every joiner is re-checked (dropped with a toast), the location
  comes from `CP.Draw.pickLocation`, and `CP.Runs.create({ ..., members in join order, leaderSrc = first joiner,
  operationId })`; cooldowns, caps and the modifier are CP.Runs' and CP.Events' (they read `operationId`).
- `onRunEnded(run, state)` *(hook)*: completed → `completed` (final, the lock lifts); anything else → `waiting`
  (`failed`, or `abandoned` when everyone left); a running operation whose run vanished for 60 s counts as failed.
  `relaunch(src)` only in `waiting`: a new window with an empty list, not a new launch (cooldown and `created_at`
  stay).
- Idle auto-cancel (`Config.CrossDept.idleCancel`): the clock starts at launch and when the run ends, is cleared while
  a run exists, is not reset by a relaunch, and never cuts an open window short; reason `sup.crossdept.reason_idle`.
- `cancel(src, reason)` — 1–200 characters (control characters become spaces, invalid UTF-8 `err.invalid_payload`),
  shown to participants; everyone still on the run leaves `cancelled`.
- Notifications: `client:operation (state, missionLabel, { id, relaunched })` (launched, started, ended, cancelled) to
  every on-duty officer; pushes `operation` and `board` on every change; toasts to participants, and to everyone with
  `launchCrossDept` when it goes to `waiting`.
- Audit (category operations, target `#<id> <missionId>`): `opLaunch`, `opStart`, `opRelaunch`, `opCancel`,
  `opAutoCancel` (console), `opRemoveJoiner`; results without an actor go to the operations webhook. Status writes are
  queued in order on one worker thread; the launch insert is synchronous. At start every open `cp_operations` row is
  set `cancelled`. `history(args)` (callback `admin:getOperations`, live and archived rows).
- Net (every `server:sup:op*` / `server:admin:op*` needs `can(src, 'launchCrossDept')`, the admin ones also an admin;
  officer paths `getOfficer`):

| Kind | Name | Payload → reply |
|---|---|---|
| action | `server:joinOperation` | `operationId` or `{ operationId }` (nil = the active one) → `{ id, joined, max }` or `{ waitlisted, position }` |
| action | `server:leaveOperation` | → `{ left }` |
| action | `server:sup\|admin:opLaunch` | `{ missionId }` → `{ id }` |
| action | `server:sup\|admin:opStart` | → `{ runId, participants }` |
| action | `server:sup\|admin:opRelaunch` | → `{ id }` |
| action | `server:sup\|admin:opCancel` | `{ reason }` → `{ id }` |
| action | `server:sup\|admin:opRemoveJoiner` | `{ src, reason }` → `{ removed }` |
| callback | `sup:getOperation` | → OperationView (`types/teams.ts`) |
| client event | `client:operation` | `(state, missionLabel, extra = { id, relaunched })` |
| push | `operation`, `board` | `{ id|false, status|false }` to every online department member (`operation` also to admins) |

  BoardData.operation adds `missionType`, `description`, `min`, `runState`, `waitlist`, `waitlistPosition`,
  `waitlistOpen`; a waitlisted viewer gets `joinBlocked = 'err.op_waitlisted'`, a full one `err.op_full` only without the
  waitlist.

### 5.18 CP.Scoring — modules/scoring (S)
Points, streaks, XP and badges. Files: `modules/{scoring,goals,cash,payouts}/server.lua` (§5.18–§5.21),
`locales/parts/economy.json`, `web/src/types/economy.ts` (every view shape), `web/src/mocks/economy.mock.ts`
(`?economy=empty|lua|edge|error`); tests `tests/economy_spec.lua` (its own database `cp_test_economy`).
- `P(mission)` — type points × `Config.Difficulty.pointsByStars[difficulty]` (boss: `Config.Events.weeklyBoss.points`),
  whole points (halves up; `points_base` is a SMALLINT).
- `compute(run, p, result, opts) -> breakdown` (§9.6 `points`, with the extras `cap`, `scoreCap`, `todMultiplier`; a
  row without them shows the shipped 2 and 2). Lines are whole points; `each` multiplies by the count (`× n`);
  penalties are negative. What counts:
  (a) every id on the mission card with its recorded count (shared `run.score.shared` + personal `p.score`), valued by
  the entry's `points` / `pctOfPoints` × P, else `Config.Bonuses`; (b) `no_participant_downed` and `no_weapons_fired`
  at the end, only when the card lists them; (c) unlisted recorded ids only when they are common personal ids
  (`pedestrian_hit`, `lights_siren` on quietPatrol missions, `shot_surrendered`) or have a value hint in
  `run.score.values` (kingpin_alive, inmate_alive, hostage_hit, ...) — an id only in Config.Bonuses does not count;
  (d) the common ones: `fast_finish` (duration ≤ fastShare × timeLimit, not with `run.flags.medals`), the modifier
  (`Config.Events.modifierPoints` × P), `first_run`, `no_vehicle_damage`, `heavy_damage` (not with `vehiclePenalties
  == false`).
  Custom missions: file values never raise points; a card entry is valued only when its id is in Config.Bonuses,
  clamped to `Config.Builder.bonusCap` (50 points / 25 % of P per occurrence); block hints still count (a positive one
  capped at `bonusCap.points`).
  Failed = floor(failedCredit × P × share), no bonuses or multipliers (reported as 1.0); abandoned = 0. A presence
  failure (§5.10) gives final 0 and $0 with the lines listed. Type of the Day (`run.missionType`; the boss is Tactical)
  applies after the cap. M_streak includes today; M_cross = `Config.CrossDepartmentPoints` with 2+ departments; M_team
  = the pay tier's `points`.
- `streak(citizenid) -> { days, multiplier, graceLeft }` — consecutive reset days with a completed counted run; each
  missed day is forgiven while its week has `Config.Scoring.streakGraceDays` left (a forgiven day adds nothing).
  `streak_days` is stored capped at 127. An approval applies the row's own day; voids never rewrite streaks.
- `isFirstRunSinceDuty(src)` — per citizenid in memory: a duty start (off → on, re-read from `getInfo`, or a load on
  duty) arms it; after a restart it counts as used when there is a completed run since today's reset. Tests never use
  it.
- XP = lifetime points of counted rows, manual_award and goal rows included; idempotent per row
  (`breakdown.xpCounted` set by a conditional UPDATE before adding, removed before taking back); never below 0.
  `levelXp(n)`, `levelOf(xp)`, `xpLevel(xp) -> { n, label, badge, xp, levelXp, nextLevelXp, prestige, next }`
  (`Config.XPCurve`; the label is the `Config.XPLevels` band), `progressFor(citizenid, gained, pending)` (pending XP
  never levels up; fills RunResult.progress from the `row:settled` listener), one level-up toast (`scoring.level_up`),
  hook `xp:levelUp`.
- Hooks `onRowCounted(citizenid, row)` (completed/failed, not flagged → XP, streak for completed, badges),
  `onRowApproved(rowId)`, `onRowVoided(rowId)`.
- `badges(citizenid) -> { id, label, earnedAt, earnedTs }` — counted over live and archived completed, unflagged,
  unvoided rows: `iron_wheels` (no_vehicle_damage), `sharpshooter` (gang_shootout with no_participant_downed),
  `road_warrior` (patrol rows), `partner_in_crime` (2+ participants), `joint_task_force` (2+ departments),
  `by_the_book`, `first_responder`; checked after every counted row and approval, removed after a void drops the count.
- `manualAward(actorSrc, citizenid, points, reason)` — admin only, whole points 1–10,000, reason ≤ 255, the officer
  must be in cp_officers (`err.unknown_officer`); a `manual_award` row with a RunResult-shaped breakdown (`kind`,
  `reason`), audited `manualAward`, the officer told when online.
- callback `getHome` → HomeData (§9.4) with `typeOfTheDay.multiplier/cap`, `card.streak.graceDays`, level,
  missionsToday and the `home:extras` hook. Home refreshes on a data-less `run` push (the run ended) and every 60 s.

### 5.19 CP.Goals — modules/goals (S)
- `forOfficer(citizenid) -> { daily = Goal, weekly = Goal }` (`Goal = { id, label, count, progress, done, points }`;
  labels from `Config.Goals`, `goals.unnamed` as fallback).
- A goal has `type`, `unit`, `crossDepartment`, `mission`, `stat` (sums that column) or missionCall (rows with a
  `mission_call_id`). Progress counts completed, unflagged, unvoided mission rows since the period start, capped at
  `count`.
- `onRunCompleted(citizenid)` *(hook)* and after an approval: a `goal` row once per period (found by `mission_id` = goal
  id + `breakdown.period`, so daily and weekly goals with one id never collide), then `goal:completed`.

### 5.20 CP.Cash — modules/cash (S)
- `compute(run, p) -> amount, breakdown` (§9.6 `cash`). The amount paid is `breakdown.cash.amount`; `round(cash_base ×
  cash_multiplier)` only when the breakdown has none (the DECIMAL(4,2) multiplier loses precision).
- `pay(rowId)` — an offline officer's row goes to `pending` (no money moves). Otherwise the claim `UPDATE ... SET
  cash_status = 'paying' WHERE id = ? AND cash_status IN ('none','held','pending') AND state = 'completed' AND flagged
  = 0 AND voided = 0` must change the row, so a flagged or voided row is never paid. Then, under pcall: an error
  before the first money call puts the row back to `pending`, after it leaves it `paying` (`stuckPayments()`), so
  nothing is ever paid twice. Step markers in `breakdown.cash.step`: `claimed` (with `payAmount`, `account`, `source`
  server|society, `societyAccount`, `txn`) before money moves, `withdrawn`, `added`.
- Daily cap (`Config.Cash.dailyCap`): paid/capped cash of rows on the row's own reset day; one officer's payments are
  serialised in-process. Final status `capped` when the cap cut it, else `paid`. Manual cash rows (`mission_id =
  'manual_cash'`) are neither cut by nor counted in it. `paidToday(citizenid)`.
- Society source: the player is re-fetched before `withdrawSociety`; false → `unfunded` ($0; the officer and his
  department's online supervisors are told). A failed AddMoney after the withdrawal is refunded with
  `depositSociety` and the row goes back to `pending`. The department comes from `CP.Access.department` (also for a
  turned-off department).
- Renewed-Banking: `recordDeposit(citizenid, amount, 'Mission payout: <label>', <department>, <name>,
  'CP-<run_uuid>-<citizenid>')` only with `Config.Cash.account == 'bank'`; the society source also
  `recordSocietyWithdraw` with the same id.
- `payPending(src)` *(hook: player loaded + 5 s, and a sweep 15 s after start for players already online)* — pays
  `pending` rows and completed unflagged mission rows still `none` with `cash_base > 0`; then `officer:loaded`.
- `release(rowId)` (the caller cleared `flagged` first; never a voided row), `forfeit(rowId)` (voided held/pending
  only; fires `row:forfeited`). Forfeiture job (at start, then every 10 min): voided held/pending rows older than
  `Config.Disputes.windowHours` without an open dispute → `forfeited`; it skips during maintenance and holds the busy
  lock (`forfeiture`).
- Maintenance: `pay` and `payPending` do nothing while `CP.Maintenance.active()`; the rows are paid after the restart or
  on `maintenance:changed (nil)`. A `left_behind` store never pays.
- `range(missionType, members) -> min, max` (pool from `CP.Draw.pool`; max includes `modifierCash` when
  `modifierChance > 0`, never for the boss; empty pool → the type payout), `earnedThisWeek(citizenid)`,
  `stuckPayments()`, `amountOf(row)`, `txnOf(row)`, `department(key)`, `rowBusy(rowId, citizenid)`, `paymentsHeld()`,
  `nextForfeitureAt()`.
- Admin money tools (§5.40), each `-> ok, data | false, errKey`; claim first, then `audit(info)` (false: the claim is
  undone, `err.audit_failed`), then the money under the officer's payment lock, then the final state:
  `markPaid(rowId, audit)` (no money), `payAgain(rowId, audit)` (at step `withdrawn` only AddMoney, at `claimed` both,
  at `added` refused; txn `-r2`; online only), `payCapRest(rowId, audit)` (owed − paid, txn `-r`, stays capped),
  `clawback(rowId, amount, audit)` (`cash_reclaimed + ? <= cash_paid`; refused when the balance is lower; txn
  `-back<n>`; the department refunded only for society source), `toPending(rowId, 'unfunded'|'forfeited')`,
  `backFromPending(rowId, from)`, `adminForfeit(rowId, 'voided'|'cancel')` (`voided` needs no open dispute and fires
  `row:forfeited`; `cancel` keeps item rewards).

### 5.21 CP.Payouts — modules/payouts (S)
- `typePayout(type) -> amount, adminLocked`, `missionPayout(missionId)`, `baseFor(mission) -> B`, `sourceFor(mission)
  -> 'admin'|'type'|'event'`, `list() -> { types, missions }`.
- `setType(src, type, amount|nil, reason, role, { unlock })` (nil = clear, admin only; `unlock` leaves the type open to
  supervisors, audited `unlocked:<amount>`), `setMission(src, missionId, amount|nil, reason)` (admin only; a new payout
  only for a loaded mission; stored payouts of missions not loaded are listed with `missing = true`).
- Supervisor range = ceil(default × low share) .. floor(default × high share), within Config.Cash limits; supervisors
  always need a reason, admins unless `Config.Payouts.requireReason = false`; an unchanged value is refused
  (`err.payout_unchanged`). Supervisor values are stored (admin_locked = 0) and start the 30 min cooldown through
  `updated_at`. `updated_by` / `set_by` = citizenid or `'console'`.
- `previewAdjust(src, { mode = 'pct'|'amount', value, scope = 'types'|'missions'|'both' })` (−90..+500 % or ± an
  amount, each clamped to `Cash.minPayout`–`maxPayout`; the token binds every entry and its old value) and
  `adjustAll(ctx)` (each change through `setType`/`setMission`, plus `payoutsAdjustAll`; `lockTypes` locks every changed
  type).
- Audit: actions `setTypePayout`, `clearTypePayout`, `setMissionPayout`, `clearMissionPayout` (old/new amounts or
  `config:<n>` / `type:<n>` / `event:<n>`), role supervisor|admin|console; without modules/admin it writes cp_audit
  directly.
- Net:

| Kind | Name | Permission |
|---|---|---|
| callback | `getHome` (scoring) | `CP.Access.getOfficer` |
| callback | `sup:getPayouts` | `setTypePayout` |
| callback | `admin:getPayouts` (rows with `outOfRange`, view `outOfRange`, `supervisorRange`) | admin + `setMissionPayout` |
| action | `server:sup:setTypePayout { type, amount, reason }` | setTypePayout |
| action | `server:admin:setTypePayout { type, amount \| null, reason, clear?, unlock? }` | admin; clearing = `clearPayout` |
| action | `server:admin:setMissionPayout { missionId, amount \| null, reason, clear? }` | `setMissionPayout`; clearing = `clearPayout` |

  Pushes `payouts` and `board` to every online player after a change, and on `settings:changed` of `MissionTypes.*`,
  `Cash.*`, `Payouts.*`, `Events.weeklyBoss.payout`, `Difficulty.cashByStars`. Supervisor Payouts counts cooldowns
  down locally and refetches when one ends.

### 5.22 CP.Leaderboard — modules/leaderboard (S)
Boards, profiles and the weekly announcements. Files: `modules/leaderboard/server.lua`, `modules/challenge/server.lua`
(§5.23), `locales/parts/boards.json`, `web/src/types/boards.ts` (every shape), `web/src/mocks/boards.mock.ts`
(`?boards=edge|empty`); tests `tests/boards_spec.lua` (a five-officer week and a three-week SAST/FIB season with known
numbers), `tests/boards_metrics_spec.lua`. Both Lua headers document every response shape.
- callback `getBoard({ period, filter, department, metric })` → Board (§9.4). Counted rows = `voided = 0 AND flagged =
  0`; points = `SUM(final_points)`; `runs`/`failed` leave out `manual_award`/`goal` rows. Filters: a type key (the boss
  is stored as `tactical`), `unit` (participants ≥ 2), `cross` (departments_n ≥ 2), `department` (award rows
  included); errors `err.invalid_filter`, `err.invalid_period`, `err.unknown_department`, `err.invalid_metric`.
- Metrics (`Config.Leaderboard.metrics`): points (XP on All-time), missions, arrests, impounds, citations, rescues,
  calls (rows with a mission_call_id), judgement (decisions_best ÷ (decisions_ok + decisions_bad), ranked only with
  `minDecisions`), live_catches (not shipped). Stats come from counted completed rows only, all-time through the
  archive union; `lethal` is never read by a board query and no payload carries kills.
- `Config.Leaderboard.minRunsToRank` counts inside the board's window and filter; All-time uses lifetime completed
  runs and `cp_officers.xp` and is always Overall. Ties: the value, (judgement) decisions, points, fewer failed,
  "reached first" (the latest counted row that changed the total), citizenid.
- The Season board shows the active season's rows, between seasons the last ended one (`season.active`); none ever →
  empty. `me` is always present (`rank = 0` = not ranked yet; the viewer sees his own name even when hidden). Rows
  carry `value`, `metric`, `level = { n, badge }` and `avatar` (a hidden name shows callsign initials).
- Cache: one entry per (period, filter, department, metric, window) for `Config.Leaderboard.cacheSeconds`; concurrent
  misses share one query. `invalidate()` *(hook: void/approve)* drops boards, season points and announcements and
  calls `CP.Challenge.invalidate()`; a result whose query was in flight during an invalidate is returned once, not
  cached.
- callback `getProfile(citizenid|nil)` → Profile: the last 20 rows of any type (award rows never disputable).
  Someone else's: callsign when hidden, no cash, the breakdown cut to the RunResult fields without `cash`, flagged and
  voided rows still listed. `canDispute` = own row, not an award, flagged/voided/failed, within
  `Config.Disputes.windowHours`, and no `cp_disputes` row ever (one dispute per row). Extras: `departmentLabel`,
  `seasonPoints`, `disputeWindowHours`, `badges[i].kind` (`week`|`champion`|`top10`|`achievement`), bio, avatar, level,
  commendations, mdtCommendations (`Config.Profile.showMdtCommendations`), service `{ lifetime, season }`, bests,
  favouritePartner, and on the own profile cleanArrestRate (arrests ÷ (arrests + lethal)). `profile(viewer, target, {
  staff = true })` is the admin view. Action `server:setHideName`.
- `serviceRecord(citizenid, seasonId|nil) -> ServiceStats, lethal`, `personalBests(citizenid)` (fastest completed run
  per mission), `favouritePartner(citizenid)` (most shared completed runs), `seasonPoints(citizenid)`.
- `announcements()` — computed from the database: the previous week's top 3 during this week and the previous month's
  during this month (`weekly_top3` / `monthly_top3`, names respect hide_name).
- Weekly job (`CP.Schedule.onWeekly`, and once 60 s after start; idempotent by the badge): `Config.Leaderboard.
  weeklyBadges` `top_<metric>_<weekKey>` to #1 of each listed metric, then Overall top 3 → `CP.Admin.webhook('board')`
  and `officer_of_week_<weekKey>` for #1 with a toast. Monthly only invalidates.
- callback `admin:getBoards` (`openAdmin`): ranked rows with `cash` (`SUM(cash_paid)` of every row, voided and flagged
  included), `realName`, `hidden`, `unranked`, `stuck` (`CP.Cash.stuckPayments()`); with `citizenid` also that
  officer's rows (Void run).
- Web: dates from the server are `'YYYY-MM-DD'` in server time and formatted at noon UTC, so every player sees the
  server's week; run tables use `table-layout: fixed` with ellipsis so long names never push the buttons out. Give
  points 1–10,000 with a reason; Void run needs a reason.

### 5.23 CP.Challenge — modules/challenge (S)
- `currentSeason()` (cached, reloaded every 5 min and after every change), `startSeason(src, name)` (ends a running one
  first), `endSeason(src)`, `standings(seasonId?)`, `bounty(weekKey?)`, `overrideBounty(src, objective)`,
  `championBanner(dept)` (the latest ended season's champion when it is `dept`), `invalidate()`.
- Weeks: week 1 runs from the season start to the first weekly reset; week n = resets since the start + 1.
  `cp_dept_bounties.winner` NULL = open, `''` = no winner; week 0 (`objective = 'season_champion'`) stores the season
  champion.
- Bounty pick: `CP.U.rng(CP.U.hash('<seasonId>:<week>')):pick(Config.Challenge.bounties)`, stored when first needed.
  Objectives `most_tactical`, `most_cross`, `most_unit`, `most_completed`, `most_arrests`, `most_calls` (an unknown id
  counts completed runs, one warning). Winner: the objective's count in that week ÷ the department's season-to-date
  active officers (`minRunsActive`); ties by completed runs, then unit runs; all zero or a perfect tie → none. Weeks
  close at the weekly reset, at start (catch-up) and at season end. Bonus = floor(bountyBonus × the winner's counted
  points that week), derived whenever standings are computed.
- Scores: `average` (points of active officers + bonuses ÷ active officers), `total`, `top10`; departments from
  `CP.Access.departments()` at call time.
- Season end: a champion only with points or runs and no perfect tie (none with `Config.Challenge.enabled = false`);
  trophies `season_<id>_champion` (its active officers) and `season_<id>_top10`; one board webhook; audit `season_end`;
  hook `season:ended`.
- Callbacks `getChallenge`, `getDeptContributors` (with avatars), `admin:getSeasons`, `sup:getDeptReport`,
  `sup:getOfficerActivity` (`viewMissionList`; supervisors get their own department, only admins pass `department`;
  activity = this week's department rows; the report's officers carry arrests, citations, impounds, decisions and
  calls; activity adds the officer's active commendations with `mine`; `err.other_department`,
  `err.unknown_officer`). Actions `server:admin:startSeason`, `endSeason` (`seasons`), `overrideBounty`
  (`bountyOverride`); permission before the payload; `err.busy` during another season change.

### 5.24 CP.Disputes — modules/disputes (S)
Files for §5.24–§5.26: `modules/{admin,disputes,anticheat}/server.lua`, `locales/parts/oversight.json`,
`web/src/types/oversight.ts` (every response shape), `web/src/mocks/oversight.mock.ts` (answers through `luaify()`;
`?oversight=edge|empty`); tests `tests/oversight_spec.lua`.
- `server:dispute { rowId, reason }` → `{ disputeId, goesTo, kind }` — own rows only (on duty), flagged, voided or
  failed (kind priority in that order), within `Config.Disputes.windowHours` from `created_at`, never award rows, 3
  filings a minute. One dispute per row ever: `err.dispute_open`, `err.dispute_final`.
- `forSupervisor(src)`, `forAdmin()` (`admin:getDisputes`), `forOfficer(citizenid, goesTo?, viewerSrc?)`. Each
  DisputeView carries the row's debrief (`decisions` with each fact's time, `people`).
- `handle(src, disputeId, decision, reason, awardPoints)` — claim first (`status = 'open'`), then apply. Approving a
  flagged row goes through `CP.Admin.approveFlagged(..., { skipPermission, noAudit, quiet })` (one audit
  `disputeApproved`, one toast); approving a voided row clears voided and flagged, `onRowApproved`, `CP.Cash.release`;
  rejecting a voided row forfeits held/pending cash; rejecting a flagged row keeps it in the queue. A failing manual
  award re-opens the dispute. The supervisor endpoint refuses failed-run disputes; the admin endpoint answers any
  (failed: Approve and give points / Dismiss; flagged or voided: Approve / Reject without `awardPoints`).
- `supervisorCanAnswer(runUuid)` — `Config.Permissions.supervisor.handleDisputes` on and an online supervisor (on or
  off duty) of the run's departments who did not take part. New disputes toast those supervisors and post to the flags
  webhook; when it is false the online admins are told and `admin:getOfficer` lists the dispute.
- A live run counts as the reviewer's own too (a participant has no row until he leaves): `err.own_run`, hidden from
  his queue.

### 5.25 CP.Admin — modules/admin (S)
- `/CrimsonPoliceAdmin` (`Config.Tablet.adminCommand`, registered unrestricted; `CP.Access.isAdmin` decides; console
  too). No args → `CP.Tablet.openAdmin(src)`. Subcommands: `payout type <type> <amount|clear> <reason>`, `payout
  mission <id> <amount|clear> <reason>`, `award <citizenid> <points> <reason>`, `season start <name>` / `season end`,
  `suspend <citizenid> <days>`, `reload`, `test <missionId> [tier] [location]` (in game only, not in the arena; any
  order; `random` or a location number; through `CP.Testing.command`, which adds accepted testers and tier `auto`),
  `storage` (mode, rows per cp_ table, the saves folder's size), `storage copy database-to-files|files-to-database
  [force]` (§5.29), `storage mode reset` (console; = `storagemode reset`, §5.41), `check` (`CP.ConfigHealth.run()`: every
  line in the console, the counts in game). Citizenids resolve to the stored spelling or an exact/upper-case online
  id; mission ids match case-insensitively. Replies: coloured `print` in the console, `CP.Tablet.notify` in game.
  After a failed start every subcommand is refused (`admin.cmd.not_started`) except the console's `check`,
  `storagemode` and `storage mode`.
- `registerSubcommand(name, fn(src, args) -> ok, messageKey, vars, helpKey)` — other modules add subcommands
  (`missioncall`); a built-in name cannot be taken.
- A non-admin who types the command gets `err.not_admin` and, once per player per start, a console line naming the
  `add_ace identifier.<fivem:… or license:…> <adminAce> allow` that would make him one.
- `audit(actor, role, category, action, target, old, new, reason, opts)` — writes `cp_audit` and posts the category
  webhook. `actor` src, citizenid or `'console'` (src 0); role outside `supervisor|admin|console` is stored as
  `console` ("console or automatic"); category `board` and unknown ones are stored as `audit` (board posts to its own
  webhook). `opts = { noWebhook, critical, ident }`; every row stores `actor_ident` (the actor's license). Outside a
  coroutine it writes from a new thread and returns nil. `auditSync(...) -> id | false` writes in the caller's thread
  (false = a money or typed-word action moves nothing); its post is critical.
- Who audits: CP.Payouts, CP.Scoring.manualAward, CP.Challenge, CP.Testing and CP.Missions audit themselves; CP.Admin
  audits the command's reload, suspensions, `forceRecall`, `approveFlagged`, `voidFlagged`, `voidRun`; CP.Disputes
  `disputeApproved`/`disputeRejected`; CP.AntiCheat `runFlagged`, `runNoted`, `autoSuspend`.
- `webhook(category, title, description, fields, opts)` and `webhooks() -> { { category, convar, state =
  'on'|'off'|'invalid', discord } }` (audit, flags, board, builder, operations; convars `cp_webhook_*` read at call
  time; only https). The queue: one post per url every 2.1 s, 429 `retry_after` honoured, 5xx retried 3 times, 100
  posts (the oldest ordinary post is dropped, never a critical one; one post then says how many). Embed limits: title
  256, description 3500, 20 fields of 1000. The link never leaves the module.
- Review: `approveFlagged(src, rowId, reason)` (clears `flagged`, keeps `flag_reason`, then `CP.Cash.release` when
  held, `onRowApproved`, invalidate), `voidFlagged` (only while still flagged, else `err.conflict`; cash stays held
  until forfeited), `voidRun(src, rowIdOrRunUuid, reason)` (every unvoided row of a run); a void calls
  `onRowVoided` and `CP.AntiCheat.onVoided` (mission rows only). Supervisor scope = any row or live participant of the
  run in their department; `ownRunCheck(src, runUuid)` and `canReviewRun` apply to every reviewer.
- Force recall (optional reason, audited): runs involving the caller's department, tests included; never a run the
  caller is or was on (`err.recall_own_run`, tests excepted: a free reroll); a target who already left →
  `err.not_participant`. The officer gets `admin.notice.force_recalled`.
- Manual award 1–10,000 points. Text is clipped by characters (cp_* columns are utf8mb4 and strict mode refuses a cut
  sequence), webhook texts too.
- `storageStatus()` (the storage command as data; the folder setting, never a full path) and `storageCopy(src,
  direction, force)` (one at a time, never during a run, under `CP.AdminKit`'s busy lock).
- `missionLabel` names `manual_adjust` and `manual_cash` rows. `_auditWhere(args)` filters category, action or
  `actions` (up to 30: the Audit Log's Cash actions preset), actor, `actorIdent`, target, role, reason (LIKE escaped),
  dates.
- Callbacks and actions: §8.3 (permissions: `getMissionList` / `sup:getLiveRuns` need `viewMissionList`,
  `sup:getReviewQueue` needs `reviewFlagged` or `handleDisputes`, every `admin:*` needs `openAdmin`). An admin with an
  officer character sees his own department in the Supervisor UI, one without sees all. `getMissionList` carries
  `crossDeptEligible` (`CP.Operations.eligible`); `admin:getMissions` adds `switch` (`CP.Settings.missionView`);
  `admin:getOfficer` adds the last 10 suspension entries and the disputes the admin should answer;
  `admin:exportAudit` gives 5,000 rows at most (formula-leading cells prefixed with `'`, 1 export per 3 s).
- UI notes: supervisor screens poll (Mission List 20 s + push `operation`, Live Missions 10 s, Review Queue 30 s);
  suspend/unsuspend need a reason in the UI; the audit Copy button uses a selected textarea and `execCommand('copy')`
  first (FiveM's CEF refuses `navigator.clipboard`); audit dates are server-local `YYYY-MM-DD`.

### 5.26 CP.AntiCheat — modules/anticheat (S)
- `checkEvent(run, src, index, evidence) -> ok, reason` (after CP.Runs' own checks): run in progress, active
  participant, not in arena (`err.in_arena`, never flagged), 10 events/s per src, index = the current objective (a
  later one flags `unexpected_event`; an earlier or finished one is lag, `err.stale_event`), exact duplicates within
  1 s dropped (`err.duplicate_event`; blocks' `try`/`seq` keep retries distinct). Speed: server ped coords at each
  accepted event; `distance / max(1 s, elapsed) > Config.AntiCheat.maxSpeed` flags the whole run `speed`; pairs across
  a routing-bucket change are discarded.
- Two classes: only an officer's own conduct is a **flag**. `flag(run, src|nil, reason, detail)` sets `p.flagged` /
  `run.flagged` (the first reason stays), so CP.Cash holds the row and CP.Rewards its items until a supervisor
  approves; every distinct (reason, participant) is written to cp_audit (`runFlagged`, target = run id, old_value =
  citizenid, new_value = reason, reason = detail), which is where the Review Queue reads who and the other reasons.
  Test runs are never flagged. A **note** (`note(run, src|nil, reason, detail, about?)`: what a suspect does, or a fact
  to check without holding points) writes the same row as `runNoted` once per (reason, citizenid or `*`, `about`) and
  never sets a flag; the Review run detail shows a held run's notes as "Note: <line>".
- `stunMode() -> 'flag'|'hold'|'strict'|'off'` (`Config.AntiCheat.stunNeedsProof`; true reads as strict, false as off,
  unknown as flag); `stunReport(run, src, seen, netId) -> ok`: seen or off = true; unseen: flag = true + note
  `stun_unproven`, hold = true + flag, strict = false.
- `onNpcKilled(run, killerSrc)` — outside kills ≥ `Config.AntiCheat.outsideKillsToFlag` → `outside_help`.
- Presence: sampled every 5 s for in-progress runs with 2+ participants, the current objective only, with a read-only
  ctx and the block's `presence` (fallback the start and `presenceRange[3]` / `Config.AntiCheat.presenceRadius`).
  `presenceOk(run, p)` (scoring and cash at the end) records the `presence` flag with its share once.
- Idle check once per run at `startedAt + Config.AntiCheat.idleCheck`: active participants not arrived leave as `idle`.
- `onVoided(citizenid)` — voided mission rows within `voidWindowDays` since the last `autoSuspend` reach
  `voidsToSuspend` → `CP.Access.suspend(citizenid, suspendDays, 0, 'auto')` + audit `autoSuspend` (never while one is
  active).

### 5.27 CP.Testing — modules/testing
Admin test mode. Files: `modules/testing/{server,client}.lua`, `locales/parts/testing.json`, web
`admin/screens/Testing.tsx`, `hud/TestControls.tsx`, `hud/DebugOverlay.tsx`, `admin/components/SpawnCheckDialog.tsx`,
`spawnCheckStore.ts`, `types/testing.ts` (every shape; Lua `false` = no value, lists may arrive as `{}`),
`mocks/testing.mock.ts`; tests `tests/testing_spec.lua`.

Flow — invite first, then Start (nobody joins a test once it started):
1. Admin UI → Testing → **Start a test**: mission (any status: built-in, custom, disabled, archived — read from
   `missions/custom/archived/<id>.lua` with `CP.Missions.parse` + `normalize`), location (index or Random), tier (Auto
   or a fixed one; default the tier `maxOfficers` reaches), start route (default `Config.Testing.useStartRoute`).
2. Optional testers (callback `test:candidates`) and `server:test:invite { missionId, targets }`: each gets
   `client:testInvite` (toast naming the panel key) and answers on the Testing screen or with the panel key's prompt →
   `server:testRespond { inviteId, accepted }`. One lobby per admin; unanswered invites expire after 120 s, accepted ones
   after 15 min; seats `Config.Testing.maxTesters - 1`.
3. `server:admin:startTest { ..., testers }` → `start(adminSrc, { missionId, location, tier, useStartRoute, testers })`
   re-validates every tester and calls `CP.Runs.create({ test = {...} })`, so everything else is identical.
   `/CrimsonPoliceAdmin test` goes through `command(src, args)` (accepted testers join).

Rules:
- Gates: `testRun`, `Config.Testing.enabled`, `CP.Alerts.inArena` for the admin and every tester (also for inviting
  and accepting), not on a run, one test per admin (`err.test_already_running`), 2 s between starts, maintenance.
  Cooldowns and caps are never checked. The Cross-Department lock is skipped for admin tests, checked for a
  non-admin draft test (`err.operation_locked`).
- Admins need not be police: the participant record comes from `getOfficer` when on duty, else `CP.Qbx.getInfo` with
  the active job's department or the first department key, rank the grade name or `test.admin_rank`, and `job = nil`
  (no duty/job re-checks).
- A fixed tier becomes `test.forcedTier` (no rescale); Auto scales normally. A chosen location another run holds is
  refused (`err.test_location_busy`); Random uses `CP.Draw.pickLocation`.
- Controls (`server:test:control`, only the starting admin): `skip`/`restart` (`CP.Runs.testSkip`/`testRestart`, In
  progress only), `pause`/`resume`, `complete`, `fail` (`test.fail_forced`), `end` (`failRun(run,
  'test.ended_by_admin')`: the `cancelled` reason's text names operations), `teleport { target = 'start'|'objective' }`
  (refused in the arena and with `Config.Testing.allowTeleport = false`; the client re-checks the arena flag, probes the
  ground, moves the vehicle when driving and undoes only its own freeze), `debug { enabled? }`
  (`Config.Testing.debugOverlay`). Complete/fail/end are audited (`testControl`); starts `testStart`/`testDraft`.
- The debug stream (every 2 s while on, admin only, never while he is in the arena): `client:test { controls, runId,
  debug }` with counts against the caps, spawn points, waypoints, zones, AI host and timer, plus the geometry (points,
  routes, zones; capped at 240 points, 16 routes, 1200 waypoints) when the state or objective changed. The NUI gets it
  as push `test` (not through the HUD); in-world markers are drawn by the Lua client within 250 m.
- Panel key `+crimsonpolice_testpanel` (`Config.Testing.panelKey`, F7; F9 is sc-multijob's): with controls →
  `SetNuiFocus(true, true)` for the HUD panel; without → the invitation prompt while an invite is open; nothing to
  open → nothing at all. Released by the key/Escape (on key-up), when the test ends or he leaves, on a foreign arena
  value, on stop, and within 250 ms of going down (none taken while down, `test.downed`); a press within
  `panelKeyGuardMs` (300) of letting go is ignored. A mouse/pad binding sends `key = false` (Escape only).
  `releaseFocus()`, `focusKind() -> 'controls'|'invites'|nil` (CP.Diag).
- Test runs settle through CP.Runs and write nothing; the result shows what it would have earned. When the admin
  disconnects the test ends for everyone (`test.ended_admin_left`).
- `record(adminSrc, {...})` (`server:admin:recordTest`, alias `server:test:record`): only for a test this admin ran in
  the last 6 h (`err.test_not_run`), picked by its `key` (run id), claimed once; tier, testers, `def_hash` and version
  come from the test; notes ≤ 255 bytes; audited (`recordTest` / `recordDraftTest`) and posted to the builder webhook.
  `markLocationChecked` (an `unplayed = 1` row, status `checked`), `hideTestResult` (`hidden`).
- `list()` (`admin:getTests`): a location's last row is "changed" when its `def_hash` differs from the mission's
  `defHash`, is missing, or (custom) its version differs; hidden rows are ignored; each mission carries `switch`.
- `startDraft(src, def, { tier, location, useStartRoute })` (`builderEdit` or `testRun`): `test.draft = true`; the
  recorded result calls `CP.Builder.onDraftTested(missionId, version, tierName, passed, src, defHash)` (a pass counts
  only for that content). `test:state` is open to `testRun` or `builderEdit`.

Check spawn points (`Config.Testing.spawnCheck`; refused `err.spawn_check_disabled` while it or Testing is off). The
server lists the points, the admin's own game judges them with `CP.Spawn.probe` (§5.43); nothing is spawned and only
his ped moves.
- `spawnPoints(src, { missionId?, location?, point? })` (callback `server:test:spawnPoints`, testRun): the catalog, one
  mission, or one location's `{ start, points }`. A point: `{ id ('spawns[7]', 'routes#2[3]'), key, i, kind =
  ped|vehicle|prop|marker|path (from the blocks' `pointKinds`, §7.1), as (what the probe judges), wall, model?, obj,
  block, x, y, z, h?, above, dStart?, dPrevious?, near? }` (`near` lists start/previous closer than
  `Config.Spawning.minDistance`); at most 1000 points and 64 routes. With `point` ("Teleport here", needs
  `spawnCheck.teleport`) the one row, audited `testControl`.
- `spawnCheckReport(src, { missionId, location, results })` (action, testRun): statuses `ok`, `snap`, `underground`,
  `floating`, `no_ground`, `in_water`, `in_wall`, `interior_not_loaded`, `skipped`; every bad one is one `CP.warn` with
  tag `spawncheck` (listed in System → Problems) naming mission, location, point, coords, status and ground; the
  report replaces the location's last one in memory (`spawnReports()`).
- Client actions `spawnCheck { missionId?, location? }` (refused on a run, in a vehicle, dead, in the arena, while one
  runs) and `spawnCheckStop`. In a thread: fade out, keep his coords, heading, freeze, visibility and invincibility;
  freeze, hide, make invincible; per location move to 1 m over the start, `NewLoadSceneStartSphere(start, 200.0, 0)`
  (`sceneTimeoutMs`), `CP.Spawn.visible` of the points within 200 m gives `seen`; then each point (paths `skipped`
  unless `spawnCheck.routes`; further than `moveWithin` → move there) through `CP.Spawn.probe`; the results go to the
  server; NUI push `spawnCheck` (started, location, point, done/stopped/failed with totals). Every move re-checks
  Crimson-Arena (rule 13): once the arena owns him he is never moved again; a run of his that starts, or a logout, ends
  the check where he is. Otherwise, and on resource stop, he is put back as he was. The test teleport is refused while
  a check runs and Start test is disabled. `spawnCheckStore.ts` keeps the pushes at module level, so results outlive
  the dialog; "Copy report" gives one line per point in the console format.

### 5.28 CP.Builder — modules/builder
The Mission Builder: drafts, locks, autosave, draft tests (`CP.Testing.startDraft`, `test.draft = true`), publish (a Lua
file written with `SaveResourceFile`), archive/restore, rollback, hand edits, edited built-ins, and the in-world tools
(placement, route recording, test drive). Files: `modules/builder/server.lua`, `client.lua`,
`locales/parts/builder_server.json`, `builder_client.json`; web `web/src/builder/` (MissionList, BuilderEditor and its
seven steps, BlockPanels, LocationMap, store, schema, applyResult, useDraftEditor), `supervisor/screens/Builder.tsx`
(`sup_builder`), `admin/screens/Missions.tsx` (`admin_missions`), `hud/BuilderOverlay.tsx`, `types/builder_server.ts`
and `types/builder_client.ts` (every shape below), mocks `builder_server.mock.ts`, `builder_client.mock.ts`; tests
`tests/builder_server_spec.lua` (its own database `cp_test_builder_server` and a temporary
`missions/custom/test_builder_<n>/`), `tests/builder_client_spec.lua`, `tests/int_duplicates_spec.lua`. Everything
sent or accepted is plain JSON; times shown are seconds; `serverTime` is `os.time()`.

#### 5.28.1 The draft definition
The definition of §3.2 in builder units, stored as JSON in `cp_custom_missions.draft_definition` and
`published_definition` (a copy of the published file plus `_file`). The Lua file is produced only on publish. Field
rules: `id` set by the server; `label` 1–64, `description` 0–500 characters; `type` a `Config.MissionTypes` key
(required); `departments` (`[]` = every one); officers, difficulty, `timeLimit`, `startTimeout`, `cooldown` in the
`Config.Blocks.details` ranges (seconds); `locations` ≥ `Config.Builder.minLocations` (edited built-ins
`minLocationsOverride`, 3), at most 20; a start radius 20–150 m (default 60); objectives 1..`Config.Builder.maxBlocks`;
`scaling` at most 20 (`"objectives.1.waves"` or `{ path, max }`); `items` at most 10, count 1–100; labels 64.

##### 5.28.1.1 Units (builder form ↔ Lua file)
- Vectors `{ x, y, z }` / `{ x, y, z, w }` (w = heading), rounded to 2 decimals when stored so the file round-trips;
  written as `vec3(...)` / `vec4(...)`.
- Chances are whole percent in the builder and two-decimal fractions in the file (`percentFields`): hostile_waves
  `surrender.chance`, `boss.surrender.chance`; flee_arrest `responses.*` (sum 100), `armedShare`; pursuit `footFlee`;
  interact_points `roll.outcomes.*.chance` (sum 100). Health shares (`belowHealth`) stay fractions.
- Progress times are seconds in the builder (one decimal) and milliseconds in the file (`secondsFields`):
  interact_points `progress.duration`, `roll.outcomes.*.followUp.duration`; protect_rescue `freeTime`; flee_arrest
  `knock.duration`, `cuff.duration`; hostile_waves `cuff.duration`; pursuit `arrest.duration`; search_area
  `clueProgress.duration`, `cuff.duration`. The upgrades' percent, seconds and spawn fields (§7.4) are handled the
  same way, and the export keeps the Lua key order.

##### 5.28.1.2 Location keys
`start` (`{ coords, radius }`) is required; every other key is named by the objectives that read it. Values: vec3,
vec4, lists of them, `{ coords, heading?, label? }` lists, lists of vec3 lists (flee routes), or a road route. The
block's `requiredPoints(obj)` lists the keys every location must have. Spawn keys (`spawnFields`: hostile_waves
`spawns`, `boss.spawn`; protect_rescue `npcs`; flee_arrest `suspect`, `associates.spawns`, `spawns`; pursuit `spawn`,
`spawns`; escort `ambushPoints`; search_area `hiding`) are ≥ `Config.Builder.minSpawnFromStart` from the start. Armed
keys (`ARMED_FIELDS`: hostile_waves `spawns`, `boss.spawn`, `spawnSets.keys`; escort `ambushPoints`; pursuit `spawn`,
`spawns`; flee_arrest `associates.spawns`) must also be outside `B.armedKeepOut(start, searchCircle)` = start radius +
`Config.Builder.spawnMargin` (2D; none at a search circle; `builder.error.spawn_armed`); a point a built-in plays at
the same start (within 0.05 m) is trusted. `B.armedTooClose(def, builtins?)` feeds the loader's warning for older
published files (they still load). A key's points further than the start radius + `maxPointFromStart` are
`builder.error.points_far`, except routes, checkpoints, fleeTo, road routes and an interact_points random key with a
point in the start circle. Markers may be near the start; no-build zones apply to every point (2D).

##### 5.28.1.3 Road routes
`{ points, stops = { { at, wait } }, loop }` — snapped road waypoints. Length (sum of waypoint distances) within
`Config.Builder.route.minLength`–`maxLength` (0.8–8 km); open route ends ≥ `minStartEndGap` (300 m) apart; a loop ends
within `loopClose` (50 m); no waypoint in a no-build zone; 2–500 waypoints; stops at most
`Config.Blocks.escort.stops[2]`, interior only, `wait` within `stopWait`. The road path between waypoints is checked
on the client while recording (the server has no path finding).

##### 5.28.1.4 Bonuses and penalties
Only `Config.Bonuses` ids: `bonuses` positive, `penalties` negative; `{ id, points }` (kind points) or `{ id, pct }`
(whole percent of P); a missing value is filled from config when stored; caps `|points| ≤ bonusCap.points` (50), `pct
≤ bonusCap.share × 100` (25); an id with `block = '<id>'` needs that block; `each` from config. File form `{ id,
points, each }` / `{ id, pctOfPoints = 0.10 }`. `B.customBonusFields` drops the objective-level ids and values the
blocks refuse on custom missions (non-standard aliveBonus/detainBonus/fastStop/ramPenaltyId/fastBonus ids and
points, `fastStop.seconds` above 120, field_contact `allCorrect`/`aliveBonus` points, process_scene `aliveBonus` to `{
id }`, a skill_check setback `penalty` not in Config.Bonuses), so the block defaults apply.

##### 5.28.1.5 Never in a definition
No payout field (`*payout*`, `cash`, `cashBase`, `basePay`, `money`, `pay`, `reward`, `rewards`) at any depth:
`builder.error.payout_field`, stripped when stored. Loader fields and `_file` are stripped. Items `armour`,
`bandage`, `ammo-*`, `weapon_*` (any case) are refused (Crimson-Arena rule 4). `RENAMED_FIELDS` reads old names as new
(`policeVehicle` → `vehicleRequired`).

##### 5.28.1.6 `published_definition._file`
`{ hash (CP.U.hashHex of the file as written; hand edits compare with it), version, publishedAt, publishedBy,
publisher ("Sergeant John Doe (SAST, citizenid ABC12345)"; an admin outside a department `(admin, citizenid …)`; `]]`
and control characters neutralised), reason = publish|rollback|code_edit|restore_file }`. A published row without it
takes the file on disk as its baseline.

#### 5.28.2 Lifecycle, versions and locks
- `status`: `draft` → `published` → `archived` (→ published by restore); the list shows Draft → Tested → Published →
  Archived (`tested` = `draft_tested = 1`). A published mission may carry a draft (`hasDraft`) of the next version.
- Versions: a new draft is v1; the first save of a published mission creates `published_version + 1`; publish
  consumes the draft; rollback and an accepted hand edit publish `published_version + 1` (rollback moves a draft to
  the next number, a code edit replaces it). Every run row stores the version it played.
- `draft_tested` is set only by `onDraftTested` for a pass of the current draft (same version, and the `defHash` that
  ran equals the stored content's hash) at `CP.Scaling.tierFor(maxOfficers)` or higher (`testAtMaxTier = false`: any);
  any stored content change resets it. Testing is optional: it is needed to publish only while
  `Config.Builder.requireTestToPublish` is true, and only for supervisors (list entries carry `needsTest`; an untested
  publish is audited `publishUntested`).
- Edit lock (`locked_by`, `locked_until`, computed in SQL): `lock`, `save`, `autosave` take or renew it for
  `Config.Builder.editLockMinutes`; held by someone else it refuses save, autosave, publish, test and discardDraft
  (`err.builder_locked`); released on publish, `unlock`, the holder's drop or unload, and `breakLock`. The UI autosaves
  every `autosaveSeconds` while it holds the lock.
- Built-ins are read-only (view, duplicate). A custom id is `custom_` + the label's slug (`[a-z0-9_]`, ≤ 30), `_2`... on
  a clash, `INSERT IGNORE` with retry; a never-published draft is renamed when the slug changes (`previousId`; a test
  started before the rename never reaches it).
- Save stores incomplete drafts and returns `errors` and `valid`; publish refuses with `err.builder_invalid`.
- Discard deletes a never-published row, else only the draft.

| Action | Own mission | Someone else's |
|---|---|---|
| builder:list / get / config, create, duplicate, validate | builderEdit | builderEdit |
| lock, unlock, save, autosave, test, discardDraft | builderEdit | builderEditAny |
| publish | builderPublish | builderPublish + builderEditAny |
| archive, restore | builderArchive | builderArchive + builderEditAny |
| rollback | builderRollback | builderRollback + builderEditAny |
| breakLock | breakEditLock | breakEditLock |

Admins always pass and may be off duty (identity from `CP.Qbx.getInfo`); supervisors must be on-duty officers.
`Begin()` lets admins past `Builder.enabled = false`. Draft tests refuse `err.in_arena`.

#### 5.28.3 Callbacks (reply `{ ok, data, error }`)
- `builder:list {}` → `{ missions = BuilderListEntry[] (every row, newest change first), builtins, me, serverTime }`;
  an entry has id, label, type, `status` (display), `dbStatus`, `version`, `draftVersion`, `hasDraft`, `draftTested`,
  `editedInCode`, `filePath`, `owner`, `updatedBy`, `updatedAt`, `lock = { citizenid, name, secondsLeft, mine }`,
  `requiredTier`, `needsTest`, `can = { edit, publish, archive, restore, rollback, breakLock, discard }`.
- `builder:get { id }` → the entry plus `definition` (the draft, or the published copy), `publishedDefinition`,
  `readOnly`, `errors`, `armed`, `backups` (versions with a `.bak`), `publishedAt`, `publishedBy`. Built-ins:
  `source = 'builtin'`, read-only. `err.builder_unknown_mission`.
- `builder:config {}` → `Config.Blocks` (verbatim), `blockList` (with `available`, default `minSeconds`,
  `presenceRange`), `allowed`, the Builder limits (maxHostiles, maxBlocks, minLocations, minLocationsOverride,
  maxLocations 20, minLocationGap, minSpawnFromStart, spawnMargin, maxPointFromStart, bonusCap), `bonuses` (from
  Config.Bonuses), `noBuildZones`, departments, missionTypes, tiers, autosaveSeconds, editLockMinutes, testAtMaxTier,
  keepBackups, exportPath, route, startRadius `[20, 150, 60]`, item limits, `percentFields`, `secondsFields`,
  `spawnFields`, `forbiddenItems`, `useStartRoute`, `templates`, `requireTestToPublish`, and the viewer's
  `permissions`.
- BuilderError `{ path (e.g. `locations.2.spawns`), message (translated), key?, vars? }`.

#### 5.28.4 Actions (`server:builder:<name>`, reply `{ ok, data | error }`)
Every action can answer `err.builder_disabled`, `err.invalid_payload`, `err.builder_unknown_mission`,
`err.no_permission`, `err.rate_limited`.

| Action | Payload | Result | Other errors |
|---|---|---|---|
| `create` | `{ type, label? }` or `{ template, label? }` (`Config.Builder.templates`: a built-in's settings and objectives, one empty location) | `{ id, record }` — draft v1, locked by me | `err.builder_bad_type`, `err.builder_unknown_template` |
| `duplicate` | `{ id }` | `{ id, record }` — "‹label› (copy)", errors show what to fix | |
| `lock` / `unlock` | `{ id }` | `{ id, lock }` / `{ id }` | `err.builder_locked`, `err.builder_read_only` |
| `save` | `{ id, definition }` | `{ id, previousId?, version, savedAt, valid, errors, draftTested, lock }`; audited | `err.builder_locked`, `err.builder_too_large` |
| `autosave` | `{ id, definition }` | `{ id, version, savedAt, draftTested, lock }`; not audited; one per 5 s | `err.builder_locked` |
| `validate` | `{ id, definition? }` | `{ valid, errors, armed, maxHostiles, requiredTier }` | |
| `test` | `{ id, tier?, location?, useStartRoute? }` | `{ id, version, tier, location, requiredTier }` — the stored draft (autosave first) through `startDraft` | `err.in_arena`, `err.builder_bad_tier`, `err.builder_bad_location`, `err.builder_invalid`, `err.builder_no_draft`, `err.builder_testing_unavailable` |
| `publish` | `{ id }` | `{ id, version, filePath, backup }` | `err.builder_no_draft`, `err.builder_invalid`, `err.builder_not_tested`, `err.builder_locked`, `err.builder_read_only`, `err.builder_file_write` |
| `archive` / `restore` | `{ id }` | `{ id, filePath }` | `err.builder_not_published` / `err.builder_not_archived`, `err.builder_file_write` |
| `rollback` | `{ id }` | `{ id, version, fromVersion }` | `err.builder_not_published`, `err.builder_no_backup`, `err.builder_invalid` |
| `breakLock` | `{ id }` | `{ id, previous }` | |
| `discardDraft` | `{ id }` | `{ id, deleted }` | `err.builder_no_draft`, `err.builder_locked` |
| `teleport` | `{ missionId, location, key, index }` | the same; the point goes to the caller in `client:builder:teleport` (`Config.Builder.teleport`; admins or a `builderTeleport` grant, `CP.Builder.canTeleport`; audited) | `err.builder_teleport_off`, `err.no_permission`, `err.in_arena`, `err.builder_on_run`, `err.builder_dead`, `err.builder_no_point` |

- Publish writes `missions/custom/<id>.lua` in the spec's custom-example shape, keeps the previous file as
  `<id>.v<n>.lua.bak` (`Config.Builder.keepBackups`), stores `published_definition`, releases the lock and calls
  `CP.Missions.register`. Archive moves the file to `archived/` and unregisters; restore moves it back. Rollback
  re-checks the newest older `.bak` against the guardrails (not the test) and publishes it with a fresh header.
- Guardrails (`B.validate(def, opts)`): every SPEC guardrail and route rule, the block's `validate` for every location
  (as a custom mission), `requiredPoints`, `armedCount`, z sanity (|x|,|y| ≤ 10000, −250 ≤ z ≤ 1500), `minSeconds` ≥ 1
  with the objectives' minimum times fitting the time limit (field_contact at least 30, process_scene 5), and
  `CP.Missions.normalize` on publish, test, validate and reloads. A mission with a `search_area` uses its search
  circle as the start: every start radius equals the first search_area's `startRadius` (200–1000 m,
  `builder.error.start_radius_search`). Every built-in's duplicate passes them (`Config.Builder.allowed.peds` holds
  every ped a built-in uses).
- Live updates: NUI push `builder { event, id, by? }` (changed, published, archived, restored, rolledBack, tested,
  lockBroken, reloaded, deleted) to everyone who opened the builder in the last 15 minutes; `client:builder { event =
  lockBroken|reloaded|deleted, id }` to the editor who lost it.
- Audit (category builder, which posts the builder webhook): create, duplicate, save (explicit), test,
  testPassed/testFailed, publish, publishUntested, archive, restore, rollback, breakLock, discardDraft, codeEdit,
  codeEditConflict.

#### 5.28.5 Server hooks
- `loadPublished() -> { def }` (for `CP.Missions.loadAll`, also at start): each published row's file, read as data;
  definitions carry the loader fields; a missing file is rewritten from `published_definition`; a changed file goes
  through the hand-edit check.
- `onReload() -> { checked, unchanged, edited, rejected, conflicts, rewritten }` (from `CP.Missions.reload`): a file
  whose hash differs from `_file.hash` is parsed, payout fields stripped (warning), checked against the guardrails
  (builder copy) and `normalize` (as written), then stored as a new version with `edited_in_code = 1` (only our
  header's `version:` line updated, an `edited:` line added; the previous version regenerated as `.bak`). A file that
  fails stays on disk unused (the last published version stays live, with a warning on every reload). If the draft
  also changed since the last publish the file wins: the draft goes to `<id>.draft.lua.bak`, is cleared, the lock
  released, the editor told, `codeEditConflict` audited. The actor is `console`.
- `onDraftTested(missionId, version, tierName, passed, src, defHash) -> bool`, `onTestHidden(missionId, defHash)` (a
  removed pass makes that draft untested again), `validate(def, opts)`, `exportLua(def, meta)` (pure).
- Edited built-ins (§8.4.2, only while `Config.AdminControl.editBuiltins` is on, admin-only in `Allows`, `VisibleTo`,
  `LoadRow`): override rows (`overrides_builtin = 1`, `base_hash` = the shipped file's hash) with files in
  `<exportPath>overrides/<id>.lua` (`.v<n>.lua.bak`, `.draft.lua.bak`, `<id>.base.lua`, `archived/`), never in
  `missions/builtin/`; `changeOwner` and `deleteMission` refuse them. `validate(def, { baseline = { def, raw } })` uses
  the shipped file as a baseline (its models, weapons and zones are allowed; a number may stay at or below its shipped
  value). `loadOverrides()`, `shippedOf(id)`, `editBuiltinsOn()`.
- Deleted custom missions go flat into `<exportPath>deleted/` as `<id>-<time>__<file>` and `__row.json`, listed in
  `index.json`. The export folders ship with a `.gitkeep`; `ensureExportDirs()` reports a missing one and
  `missingExportDirs(path)` is the Settings check of `Builder.exportPath` (`err.setting_export_folder`).

#### 5.28.6 Client protocol (builder client ↔ builder UI)
The tools take minutes (an NUI request waits 20 s), so each is started by a client action and its result delivered
later.

| Client action | Payload | Reply |
|---|---|---|
| `builderPlace` | `{ missionId, location, key, kind = ped\|vehicle\|marker\|area\|start, model?, heading, multiple, min?, max?, radius?, radiusMin?, radiusMax?, minGap?, points, start, spawn, armed?, startRadius?, otherStarts, label?, ui? }` | `{ started }` or `err.in_arena` / `err.builder_busy` |
| `builderHere` | the builderPlace payload | `{ ok, reason, point, street?, result? }` at once: the spot he stands on (or his vehicle), checked as an aimed spot; `street` names a new mission; `err.builder_here_off` without `Config.Builder.useMyPosition` |
| `builderAutoPoints` | builderPlace payload + `count`, `anchor?` | `{ ok, reason, wanted, proposed, result? }`: spots on a ring `Config.Builder.autoFillRing` beyond the key's keep-out, snapped to the navmesh or the road side, judged by `CP.Spawn.probe` and `B.checkSpot`; applied only when kept; more than 250 m away → not ok; `err.builder_auto_off`, `err.builder_auto_start` |
| `builderCheckPoints` | `{ missionId, location, ui?, start, startRadius?, offset, keys = { { key, kind?, model?, spawn?, armed?, minGap?, route?, points } } }` | `{ ok, reason, moved, failed, keys = { { key, points, failed, checked } } }`: "Move the whole location here" — every point moves by `offset`, routes only move, others are put on the ground and checked; 20 s at most |
| `builderRecord` | `{ missionId, location, key, stops, loop }` | `{ started }` |
| `builderTestDrive` | `{ missionId, location, key, route, vehicle, speed, style }` | `{ started }` |
| `builderResult` | `{}` | the pending result (or nil), cleared |
| `builderCancel` | `{}` | `{ cancelled }` |
| `builderWaypoint` | `{ coords }` | `{ ok }` |
| `builderShowMap` | `{ points = { { kind = start\|spawn\|checkpoint, coords } } }` (1–300) | `{ shown }`: temporary pause-map blips until the tablet opens again |
| `builderTeleport` | `{ missionId, location, key, index }` | the same, once he is on the ground at the server's point |

- Results (kept until read and pushed as `builder { event = 'clientResult', id, result }`, each with an increasing
  `seq`): `placement { points, radius?, cancelled }`, `recording { route, length, rejected, rejectedSamples (≤ 50),
  unreachable, droppedStops, cancelled }` (fewer than two waypoints = cancelled), `testdrive { completed, failed,
  cancelled }`. Overlays (`CP.Tablet.overlay`, every 150 ms): placement, recording, testdrive (fields in
  `types/builder_client.ts`).
- Flow: the tool closes the tablet, runs, cleans up everything it set (ghost, vehicle, driver, blips, zones,
  waypoint), stores the result and reopens the tablet on `payload.ui` 300 ms later (not after the arena, death, unload
  or deletion). The NUI keeps editor state in module memory (`builder/store.ts`), queues `clientResult` pushes, pulls
  `builderResult` on reopen (deduplicated by `seq`), applies it (`applyResult.ts`) and autosaves.

#### 5.28.7 Client rules
- Stored heights: peds at ground + 1.0 m, vehicles at their root height (`GetModelDimensions`), markers on the aimed
  surface, starts and areas on the ground.
- Spot checks (`B.checkSpot`, in order): every point placed, nothing aimed at, further than 50 m, in a no-build zone,
  water, not on the ground (more than 0.75 m from ground z or steeper than ~45°; not for markers), the capsule probe
  (peds, vehicles), armed keep-out, `minSpawnFromStart` (3D), `minLocationGap` to other starts, `minGap` within the
  key. Checks use the point as stored, which the server re-checks on save and publish.
- Recording: a sample further than `maxOffRoad` from a node is still taken on a road surface with the node within 4 ×
  `maxOffRoad`; waypoints are the snapped node positions; a turn adding up to `turnAngle` makes a waypoint; Backspace
  undoes `undoMetres` and sampling waits until he is back at the end (also after a resume or another car); E or the
  horn adds an escort stop. Each segment is checked with `CalculateTravelDistanceBetweenPoints` (≥ 100000 = no path)
  as soon as its second waypoint is kept (path nodes stream only near the player). Checkpoint routes may be recorded
  (thinned to `checkpoints[2]`, ends kept) or placed. A pursuit race loop uses keys `^raceLoop\d*$` (loop = true).
  Search areas need 6 clue and 6 hiding spots.
- Test drive: more than 200 m from the start a waypoint leads there (never a teleport); the spawn must be 6 m clear; a
  local vehicle and driver (`s_m_m_armoured_01`, fallback `a_m_m_business_01`) drive waypoint by waypoint; a waypoint
  not reached within `testDriveTimeout` goes to `failed`; stops are waited out; reckless drives as fast (a test drive
  must stay in lane).
- Refusals: `err.in_arena` (the state bag; the server re-checks the bucket), `err.builder_busy` (one tool at a time),
  `err.builder_dead`, `err.builder_on_run`, `err.builder_disabled`, `err.builder_bad_vehicle`, `err.invalid_payload`.
  A foreign arena value or being put on a run stops a running tool (checked every 250 ms; no reopen).
  `client:builder` lockBroken/reloaded stop that mission's tool (the result arrives cancelled); deleted drops it.
- Screens: the Supervisor screen is gated by `session.actions.builderEdit` and each action by its permission and the
  row's `can.*`; the Admin catalog merges `admin:getMissions` with `builder:list` (launch through `opLaunch` for
  `crossDeptEligible` missions). Autosave every `autosaveSeconds` while dirty (with a `rev` guard), before a tool,
  test or publish; leaving saves and unlocks; validation runs 1.5 s after the last change. After a Random-location
  test the UI asks which location ran.

### 5.29 CP.Storage (with CP.Storage.MemSQL) — modules/storage (S)
Where Crimson-Police keeps its data (`Config.Database`). `enabled = true` (default): MySQL/MariaDB through oxmysql,
tables built by the migrations runner, no SQL import. `enabled = false` ("database off", `'files'` in code, "the saves
folder" in owner text): every `cp_` table lives in the saves folder (`Config.Database.folder`, default `saves` inside
the resource; FXServer's sandbox only lets a resource write inside resource folders). `CP.Storage.MemSQL` is the
engine (memsql.lua creates `CP.Storage` and puts it there).

- Load order: `@oxmysql/lib/MySQL.lua`, then `memsql.lua` (defines only `CP.Storage.MemSQL`), then `server.lua`, before
  every other server module. In files mode `server.lua` opens the folder and replaces this resource's `MySQL` global
  with the shim at file load (the one exception to ground rule 5); the glob's second load returns at once.
- `CP.Storage`: `mode() -> 'database'|'files'`, `name() -> 'database'|'saves folder'`, `folder()`, `describe()` (the
  start-up line), `loadError()` (a folder that is missing, not writable or not readable: every statement fails with that
  text and nothing is changed), `hasSavedData()`, `realMySQL` (oxmysql's `MySQL` in files mode), `db`, `MemSQL`. A new
  saves folder next to a database with Crimson-Police data, or a new database next to a folder with data, is announced
  with the storage copy command.
- The storage chosen in Admin UI → System is kept in the server's resource KVP (`cp_storage_mode` = database|files,
  `cp_storage_folder`) and read before `Config.Database` (which it then reflects); a start-up line, System → Storage
  and Config health (`storage`) name the override. `effective(cfg, kvp) -> { enabled, folder }, override|nil` (pure),
  `override()`, `validFolder(f)` (relative, under `saves`, no `..`, `//` or full path). `storage mode reset` /
  `storagemode reset` (console) clears it. Each store holds `cp_storage_meta` (`generation`, `state` =
  active|left_behind): a switch writes a new generation into both and marks the old one `left_behind`; a store that
  starts `left_behind` begins that maintenance lock (§5.41).
- The migrations runner (`modules/migrations`, `CP.Migrations.ready() / isReady() / version() / started() /
  failed() / status()`): a failed statement or runner error fails the start with the file, the statement, the driver's
  error and one `How to fix it:` line for the usual first-start errors (rights, password, unknown database, host),
  the `storagemode reset` line for a storage switched in game, and `ensure <resource>`. A failed start is a state, not a
  stop (FXServer refuses StopResource on the calling resource): `ready()` raises `err.not_started` (also in threads
  waiting in it), `started()` answers false without raising, CP.Net answers every action and callback
  `err.not_started`, CP.warn/CP.err drop lines carrying it, the console command accepts only `check` and the storage
  mode reset; nothing touches the store afterwards. After `CP.Settings.boot()` and before any `ready()` caller goes on,
  it calls `CP.Sysadmin.startLocks()`. When oxmysql has not connected 30 s after start one warning names `set
  mysql_connection_string` and `Config.Database.enabled = false`.
- The database server (database mode only): before the first table statement one probe `SELECT VERSION(),
  JSON_VALUE(...)`; no JSON_VALUE (MySQL before 8.0.21) or a JSON null read as text (MariaDB 10.2) fails the start
  ('the database server is too old'; fix: MariaDB 10.9+ or the saves folder), since every payment step uses JSON_VALUE.
  MySQL with it starts with one warning (Qbox does not support MySQL; LiveCtl's marker compare-and-set never matches a
  JSON column there, and a copy can reuse a deleted run id). After the migrations every cp_ table not in utf8mb4
  (txAdmin's recipe makes the database utf8) is converted, one line each, its JSON columns back to `utf8mb4_bin`; a
  failure is a warning. `storage copy files-to-database` runs the same switch (`CP.Migrations._utf8mb4Tables`).
- `CP.Storage.MemSQL` (also runs under plain lua5.4 in the tests): `new({ store })`, `db:exec(sql, params) -> { kind =
  'rows', cols, types, rows, n } | { kind = 'write', affected, changed, insertId, info, warnings }` — synchronous,
  atomic, saved before it returns (`.tmp` then rename in a crash-safe order; a failed save is undone in memory and on
  disk). With `db.slice` a SELECT in a thread gives the server its turn every 4 ms and other statements wait for it.
  JSON_EXTRACT/VALUE/CONTAINS answers are memoised per (path, text) (`jmemo`, two generations,
  `Config.Database.jsonCacheEntries` 100000). A DELETE of more than 64 rows (`BULK_DELETE_ROWS`) sweeps the index
  buckets once at the end. `db:load()`, `db:bulk(fn)` (one save at the end), `db:tableNames()`, `folderStore(dir, {
  docRows, label })` (the file layout is in memsql.lua's header), `luaRows(res)`.
- The shim `MemSQL.shim(db, { realMySQL, resource })`: `query`, `single`, `scalar`, `insert`, `update` (callback or
  `.await`) and `ready`, with oxmysql's return shapes, typing (TINYINT(1) booleans, DECIMAL and SUM strings, DATETIME as
  ms, UPDATE counting matched rows), errors and parameter checks; any other key raises. With
  `Config.Database.saveTurnMs` (4; 0 = never) a thread that spent that long saving yields after the statement (never
  inside one), as oxmysql's await does. Only `cp_` tables go to the engine; other resources' tables (today
  `mdt_dispatch`) go read-only to `realMySQL`; mixing both or writing another resource's table is an error.
- Supported SQL (the full list is memsql.lua's header; anything else fails with "the saves folder engine (files mode)
  does not support ..."): SELECT [DISTINCT] from tables, derived tables or DUAL with [INNER]/LEFT JOIN, WHERE, GROUP BY,
  ORDER BY, LIMIT/OFFSET, UNION ALL in derived tables; INSERT [IGNORE] VALUES or SELECT with ON DUPLICATE KEY UPDATE;
  UPDATE [IGNORE]; DELETE incl. joined; CREATE TABLE / LIKE / INDEX; ALTER TABLE ADD column or index; types INT,
  TINYINT, SMALLINT, MEDIUMINT, BIGINT, VARCHAR(n), DECIMAL(p,s), DATETIME, DATE, ENUM, JSON; `+ - *`, comparisons,
  logic, IS NULL, IN, EXISTS, subqueries, LIKE, CASE, `± INTERVAL n SECOND|MINUTE|HOUR`; COUNT SUM MAX MIN GROUP_CONCAT;
  COALESCE IFNULL NULLIF IF GREATEST LEAST ROUND DATE DATE_FORMAT UNIX_TIMESTAMP FROM_UNIXTIME NOW CURRENT_TIMESTAMP
  TIMESTAMPDIFF SUBSTRING_INDEX CHAR_LENGTH LOWER UUID JSON_SET JSON_REMOVE JSON_EXTRACT JSON_UNQUOTE JSON_VALUE
  JSON_VALID JSON_CONTAINS JSON_TYPE. MariaDB semantics: utf8mb4_general_ci with MariaDB's weight and LOWER tables
  (`tools/gen_collation.py`) and PAD SPACE, NULL logic, strict mode errors and warnings, BIGINT overflow (1690), NULLs
  first ascending, MariaDB's messages, the server's local time zone. Not supported (unused): comma/RIGHT/CROSS joins,
  HAVING, BETWEEN, WITH, window functions, UNION without ALL, AVG, DISTINCT inside an aggregate, `/ % DIV MOD REGEXP`,
  other INTERVAL units, TEXT/CHAR/TIMESTAMP columns, fractional seconds, other ALTER forms, RENAME/DROP/SET/SHOW, table
  parameters, `MySQL.prepare`, transactions. A migration adding a NOT NULL DATETIME/DATE column to a table with rows
  needs a DEFAULT.
- Rule for new SQL: modules never test the mode; a new statement uses only these constructs or extends the engine with
  MariaDB's exact behaviour; the suite must pass in all three storage modes and `--storage=shadow` report 0 differences
  (plus `--fuzz` after an engine change; §11). A statement on another resource's table only reads, never with a cp_
  table.
- Storage copy (`/CrimsonPoliceAdmin storage copy database-to-files|files-to-database [force]`, console or an admin):
  every `cp_` table but `cp_schema_migrations` between MariaDB (the real oxmysql) and a saves folder engine. It runs the
  source's migrations on the target first; keeps ids and AUTO_INCREMENT counters (an engine target inside one
  `db:bulk`); into the storage in use it raises the counters first and writes with ON DUPLICATE KEY UPDATE; moves
  DATETIME through UNIX_TIMESTAMP/FROM_UNIXTIME and DATE as `YYYY-MM-DD`; is refused during a run or an operation and
  into a target with rows unless `force` (which empties it); empties the target again on failure; is audited
  `storageCopy` (also in the target's cp_audit). `/CrimsonPoliceAdmin storage` prints mode, path, rows and size.
- Tests: `tests/memsql_spec.lua` (MariaDB's answers, the collation table, a crash at every point of a save, FXServer's
  inverted `os.rename`, hand-edited documents, slicing, the bulk DELETE), `tests/storage_spec.lua` (files mode end to
  end, a restart, 50,000 runs with timings and sizes), `tests/storage_copy_spec.lua`. `--storage=files` runs the whole
  suite in files mode; `--storage=shadow` checks the engine against MariaDB statement by statement (§11).

---

### 5.30 CP.Custody — modules/custody (police actions, contacts, custody chain)
Truths, facts, police actions, grading, the custody chain and the service vehicles (prisoner van, tow truck, coroner
van). Files: `modules/custody/{server,client}.lua`, `locales/parts/custody.json`, the blocks `field_contact` and
`process_scene` (§7.4), web `officer/components/ContactPanel.tsx` (replaces the Business Check log on Active Mission
when `view.contact` has entries), `hud/ContactCard.tsx` (HUD patch `contact`), `types/custody.ts`, mock
`mocks/custody.mock.ts` (`?contact=1`). Truths, demeanours and cues live only in this module's book per run (never in
`run.entities`, a bag, an event or a push).
- `rollTruth(rng, setName, role)` (`Config.Custody.profileSets[set][role]`, role person|driver|passenger|vehicle,
  falling back to person then driver; weighted over sorted keys), `rollDemeanour(rng, truthKey)`
  (`Config.Custody.demeanour[truth]`; only an armed truth can be hostile), `rollProfile(rng, setName, role, hasCar,
  truth?) -> { truth, demeanour, cues }` (in one fixed order: where (person or car; never car for a hostile),
  plainView, odour, admits (`Config.Custody.admission`), consents, bolts (runner always, nervous 15 %), minor).
- `register(run, obj, netId, contact)` — the record `{ kind, role, label, truth, demeanour, cues, vehicleOf, owner,
  spot, level, actions, allowWarn, observed, evading, custody, revealed, state, consensual, transportPoint, caught, ran,
  chain }`; the bag gets only `contact = { label, kind, actions }` and the state (actions never depend on the truth);
  `revealed` facts are known from the start; each person is noted for the people debrief. `get(run, netId)`,
  `contactsOf(run, obj|nil)`.
- `act(run, netId, behaviour, args)` — the only truth-derived signal to a client: `client:contactAct { runId, netId,
  behaviour, args, seconds }` to the host when it starts, once per behaviour per contact. walk_away, leave,
  exit_and_stand, walk_to, drive_off; flee_on_approach, flee_on_order and tell_then_draw play a `Config.Npc.tellSeconds`
  tell first (participants within tellRange get a `custody.tell.*` hint); tell_then_draw then `CP.Runs.arm` and
  hostile.
- `begin(src, runId, netId, action, extra)` / `finish(...)` — every action: live in-progress run, active arrived
  participant, on duty, not in the arena, the owning objective current, the action in its list, the state order, reach
  at both ends (server coords), finish ≥ `Config.Custody.times[action] − actionSlack`, and for actions of 3 s or more
  the CP.Npc dwell sampler (in reach for the time − 2 s). A cancelled bar sends no finish and counts for nothing.
- `reveal(run, netId, factKey, src, data)` — sent to every active participant now (the panel is pushed, a HUD line);
  `data.suppressed` = inadmissible (struck through, never graded, never a cause, never a knowing error; found again
  lawfully it counts from then). `knownTo(run, factKey, netId, src) -> ms|nil` (a knowing error needs it ≤ the
  decision's begin). `probableCause(run, vehNetId) -> bool, sources` (plain_view, odour, admission, weapon, arrest,
  stolen, consent).
- `grade(run, netId, choice, src, beginMs) -> entry, failFact` — pure: the Dispositions table with the mission's and
  objective's `decisions` overrides (`{ wrongfulArrest = 'fail' }` makes it critical) and `Config.Decisions`; Best only
  with the deciding fact admissible; points 0 for a caught runner or a `revealed` deciding fact; adds the factLog.
- Decisions: `warn` (stops only, `allowWarn`), `cite`, `release`, `arrest`, `noAction`, `impound` (a car), `cite` (a
  parked car). Citations and impounds graded Best/OK → `noteStat`; Arrest → `noteArrest` through `decide`; let-go people
  are released and removed after releaseDespawn; a stopped car whose people all went drives off; someone let go while
  seated in an undecided car waits until the car is settled. A case-failing choice with
  `Config.Decisions.confirmKnownErrors` decides nothing until confirmed. A failed effect is refused with its error.
- `enableChain(run, netId, opts)` — after a cuff, for any block: searchPerson, escort, seat, handover, and the transport;
  `{ type = 'handed_over' }` to the owning objective. `requestTransport(run, coords, { obj, point })` (a request while
  the van is on its way moves it; one after it left sends a new one), `transport(run, src) -> { status, netId,
  distance }`, `impound(run, netId, src)` (`Config.Custody.tow`; `enabled = false` fades the car at once).
- `serviceVehicle(run, kind = transport|tow|coroner, coords, { obj, point, target, decider })`, `checkRoadPoint(run,
  handle, reply, side)`, `releaseService`, `serviceStatus(handle)`, `_servicesOf(run)`. The driving client is the
  nearest active participant outside the arena (else the host; handed on when he leaves, goes down, enters the arena or
  is beyond serviceHandoff). It is asked (`client:roadPoint`) for a road point 150–250 m away; the server checks it
  (spawnDistance ±5 m, `Config.Custody.serviceClearance` 30 m from every player) and retries every 3 s. Vehicle and
  driver spawn through CP.Runs, locked. Arrival = within 15 m of the parking point below 1.5 m/s (the van without a
  transport point: within `transport.parkWithin` of the scene). After serviceTimeout a van is placed at its parking
  point (only while no player is within serviceClearance; then it waits frozen for `CP.Spawn.again`) and a tow that did
  not load fades the car (impounded). A van without a road point asks for one beside the scene (30–70 m from the
  parking point) or waits; a tow truck without one is never made. The tow loads within 8 m of the flatbed. The van
  leaves `transport.leaveAfter` after its objective is done, the coroner when process_scene releases it; leaving
  vehicles are deleted 25 s later with driver and cargo. `Config.Spawning.enabled = false`: vans are placed directly.
- `onCuffed`, `markGone(run, netId, how)`, `markDead`, `closeObjective(run, obj) -> n` (undecided contacts:
  `Config.Decisions.undecidedAtEnd` (missed_offence −5) for the officer who last worked each, never a fail),
  `noteForce(run, netId, src)` (excessive_force, once per person per 10 s), `view(run, obj, src) -> ContactView|nil`
  (choices' `failsCase` only from facts that reached this viewer, and only for a knowing error; `confirm` when a
  confirm waits), `giveEvidence(run)` (`Config.Custody.evidenceItem`, off; on run:inProgress, one item per
  participant of a run with a field_contact or process_scene objective, taken back like every mission item).

| Name | Side | Payload |
|---|---|---|
| `server:custody` | C → S plain, 4 per 2 s | runId, netId, action, phase `'begin'\|'finish'`, extra (`{ offence }`, `{ door }`); `runPlateFromVehicle`, `seat`, `handover` may send netId 0 (the car in front, the person escorted, everyone escorted or seated) |
| `server:contactDecide` | NUI action | `{ runId, netId, choice, offence?, confirmed? }` → `{ ok }` or `{ confirm = { factKey } }`; within 25 m; a confirmed choice uses the begin time of the ox_target choice that asked (60 s) |
| `server:stunHit` | C → S plain, 2/s | netId; accepted only when CP.Npc saw a ragdoll or state change of that detained, escorted, seated or compliant ped within 1 s |
| `client:contactAct` | S → host | `{ runId, netId, behaviour, args, seconds }` |
| `client:contactConfirm` | S → decider | `{ netId, choice, factKey }`: the tablet opens with push `contactConfirm` |
| `client:serviceVehicle` | S → driving client | `{ runId, id, op = 'drive'\|'load'\|'leave', kind, veh, driver, dest, target, away }` |
| `client:serviceBlip` | S → participants | §5.44 `service` |
| `client:roadPoint` | ox_lib callback S → C | `{ near, min, max }` → `{ coords, heading }` or nil |
| client action `contactAction` | NUI → client | `{ netId, action }`: closes the tablet and runs the begin/bar/finish flow |
| HUD patch `contact` | S → C | `{ label, fact, hint, confirm, suppressed }` (CP.Lt tokens) |

Client (`modules/npc/client.lua`, `modules/custody/client.lua`): ox_target options `crimson-police:contact_<action>`
on peds and vehicles, `crimson-police:custody_escort`, per door `crimson-police:seat_<action>_<door>` (bones
door_dside_f, door_pside_f, door_dside_r, door_pside_r), all reading the cp bag only; the `crimsonpolice_contact` key
(`Config.Tablet.contactKey`: Run plate from the driver seat, Hand over at the van, Place in vehicle, Escort on/off);
host tasks for escort, stand, leave, the tells and behaviours; `CP.Custody.perform` (the begin/bar/finish flow), the
confirm, the road point callback and the service vehicle driving.

### 5.31 CP.MissionCalls — modules/missioncalls (Dispatch)
The tablet's own call board. Files: `modules/missioncalls/server.lua`, `client.lua`,
`locales/parts/missioncalls.json`; tests `tests/missioncalls_spec.lua`. The Officer Dispatch screen, the board's
"n mission calls open" link, MissionCallsPanel (Supervisor Live Missions, Admin Missions → Dispatch),
AreaCoverageMatrix (Admin Testing) and LocationPlays (Admin Missions) read it; mock `mocks/missioncalls.mock.ts`
(`?calls=empty|run|op`).
- `list(src) -> DispatchView` — only for officers with the tablet open (callback `getMissionCalls`, push `calls` to
  watchers).
- `eligibility(src) -> { at, unit, types }` — every accept check (`CP.Draw.check`), the eligible pool after no-repeat,
  missions and locations per area, the card's cash and points; cached per unit for
  `Config.MissionCalls.eligibilityCache` s and cleared on row:settled, participant:left and duty changes. The
  no-repeat history and hourly/daily counts are read once per officer until his next settled row or duty change (a
  count at its cap is read again every 60 s); a claim reads them fresh. No query per call or per viewer.
- `areaFor(src, call)` — the area a call names to that viewer, only with `minMissionsPerArea` missions and
  `minLocationsPerArea` locations in his pool there; nil = county-wide. `areaOf(coords)` (nearest centre),
  `areaIndex()` (the coverage matrix). Turned-off locations count in no area.
- `claim(src, callId) -> ok, { runId } | { pending } | errKey` — every accept check, then the call's rules (excluded
  citizenids, the issuer's unit for the whole offer, paged, priority window, a pool in the area). Claims within
  `claimWindowMs` are ranked by the nearest member's distance to the area centre, then fewer calls won in the last
  hour, then the earliest; losers get `err.mc_taken_by`. The row moves open → claimed (`UPDATE ... WHERE status =
  'open'`) before the accept; a declined ready check puts it back with its remaining offer time, excludes the
  declining unit by citizenid and tries the next claimant. `err.maintenance` during a maintenance lock.
- Staff calls: `withdraw(src, id, reason)`, `page(src, typeKey, area, leaderSrc)`, `create(src, typeKey, area, {
  skipWait, reason })` (an admin's **Post anyway** during the wait between staff calls, audited `mcCreateSkipWait`;
  supervisors still wait); audited (category operations); `missionCall.staff = true`, so no rapid_response. A paged
  call toasts only the paged unit; when pageTime ends the other idle units that could claim it get the toast once.
- `claimableCount(src)` (Home and board `callsOpen`), `stats(citizenid) -> { answered, avgResponse, rapid }`,
  `supView(src) -> SupCallsView` (claimed calls of other departments hidden from supervisors), `history(args) ->
  Paged` (callback `admin:getMissionCalls`), `closeLeftover()` (at start: rows left `open` become `lapsed`, `claimed`
  become `closed` with outcome `restart`; calls live in memory).
- Hooks: run:arrived, run:ended (close with the outcome, or re-dispatch once — the claim's members excluded — when
  nobody arrived and the end reason is quit, off_route, start_timeout, idle, real_call or force_recall), row:settled
  and participant:left (cache), home:extras. `CP.Schedule.onDaily` deletes history older than
  `Config.Retention.missionCallDays`. `/CrimsonPoliceAdmin missioncall <type> [area]`.
- Net: callbacks `getMissionCalls`, `sup:getMissionCalls`, `admin:getAreaCoverage`; actions
  `server:claimMissionCall`, `server:declineMissionCall`, `server:sup:mcWithdraw|mcPage|mcCreate`, `server:admin:*`;
  plain `server:mcWatch` (deprecated; the `tablet:closed` hook ends the watch, so the client runs no poll);
  `client:missionCall` (toast and tone, only to members of idle units who could claim and have not set
  `cp_officers.calls_muted`, read at most every 30 s; the client drops it on a run or in the arena). Nothing is ever
  sent to SC-Dispatch.

### 5.32 CP.Profile — modules/profile (pictures, bio, look, commendations, moderation)
English only: a profile has no language. Web: `shared/components/Avatar.tsx` (presets `web/src/assets/avatars/*.svg`;
links fall back to initials), `officer/components/{ProfileEditDialog,CommendationsCard,ServiceRecordCard,LookCard}.tsx`,
`supervisor/components/{CommendDialog,ProfilesReview}.tsx`, mock `mocks/profile.mock.ts`.
- `avatarOf(row, { own })` (approved link or preset, else initials; frame = the level badge; a hidden name shows the
  callsign's initials, never the picture, unless own), `avatarFor(citizenid, viewerSrc|nil)`, `prefsFor(citizenid) ->
  { appearance, accent, uiScale (clamped to Config.Profile.uiScale), callsMuted }`.
- `commendations(citizenid, { staff, viewer })` (active, newest first; `staff` adds revoked ones; `viewer` adds `mine`;
  a hidden issuer shows by callsign), `newCommendations(citizenid)` (last `Config.Commendations.announceDays`, 60 s
  cache).
- `validateBio(text)` (≤ bioMax characters and bioLines lines, control characters removed, no word or phrase of
  `Config.Profile.bannedWords` or `config/banned_words.txt`), `validateUrl(url)` (https, an exact host of
  `avatarUrls.hosts`, ≤ 255, a .png/.jpg/.jpeg/.webp path, no spaces, quotes, backticks, backslashes or angle
  brackets).
- `report(src, citizenid, reason, note)` (picture, bio, other; never your own; one per profile per reporter per day,
  `Config.Profile.reports.perDay`; audited `profileReport`), `set`, `editView`, `queue(dept|nil)`,
  `adminView(citizenid)`.

| Name | Payload | Rules |
|---|---|---|
| callback `getProfileEdit` | → ProfileEdit (+ bioPending) | own |
| `server:profile:set` | `{ bio?, avatar? = { kind, value }, appearance?, accent?, uiScale?, callsMuted? }` → `{ pending }` | picture and bio share `Config.Profile.editCooldown`; a preset above the level is refused; a link needs `avatarUrls.enabled`, counts toward `perDay`, and with `requireApproval` waits in `avatar_pending`; `bioRequiresApproval` → `bio_pending`; accent only from the department's `personalAccents` at or below the level; the mute saves `calls_muted` and clears MissionCalls' cache |
| `server:profile:report` | `{ citizenid, reason, note? }` | any officer |
| `server:sup\|admin:reviewAvatar` | `{ citizenid, decision = 'approve'\|'reject', reason, what? = 'avatar'\|'bio' }` | reviewProfiles, own department (admins any), never your own, reason required, a claim UPDATE; audited reviewAvatar / reviewBio |
| `server:sup\|admin:clearProfile` | `{ citizenid, what, reason }` | same; audited clearBio / clearAvatar |
| `server:sup\|admin:handleReport` | `{ id, decision = 'clear'\|'dismiss', reason }` | same, on the report's department; clear also clears the content; final once handled |
| `server:sup\|admin:commend` | `{ citizenid, kind, citation, runUuid? }` → `{ id }` | issueCommendation / openAdmin; kind from `Config.Commendations.kinds`; never yourself; supervisors own department unless `crossDepartment`, `perSupervisorPerDay`; `sameKindCooldownDays`; a run must be the recipient's and not the issuer's. Zero points: only cp_commendations and the audit row are written; toast, Home news, optional board webhook |
| `server:sup\|admin:revokeCommendation` | `{ id, reason }` | the issuer or any admin; audited |
| callback `sup:getProfileQueue` | `{ department? }` → ProfileQueueItem[] | reviewProfiles; reports show the live content, never the reporter |
| callback `admin:getOfficerProfile` | `{ citizenid }` → the staff profile with realName, pending values, every commendation, open reports | openAdmin |

Push `profile` (`{ citizenid }`) to the officer after every change. Hooks: `home:extras` (commendation count and news,
from the cache only), `officer:loaded` (warms the cache).

### 5.33 CP.Rewards — modules/rewards (optional item rewards)
Off by default (`Config.Rewards.enabled = false`): no listener writes a row and nothing calls ox_inventory. Only admins
set rewards, in config; mission files and the Builder never carry a reward field. Files: `modules/rewards/server.lua`,
`locales/parts/rewards.json`, web `types/rewards.ts`, `officer/components/RewardsLocker.tsx` (on Home, hidden while
empty), `admin/components/ItemRewardsPanel.tsx` (Admin UI → Leaderboards → Item rewards), mock `mocks/rewards.mock.ts`
(`?rewards=off|arena`).

Data: `cp_item_rewards`, one row per officer, source, source key and item (`uq_reward`); `row_id` is the run row for
run, medal and boss rewards (held and forfeited with it), NULL otherwise. Times from `os.time()`, never NOW().

| source | source_key | when |
|---|---|---|
| run | run_uuid | row:settled: the run entry's rolls |
| medal | run_uuid | row:settled: `Config.Rewards.medals[gold/silver/bronze]` from row.medal |
| boss | `week:<weekKey>` | row:settled of a Weekly Boss run, once per week |
| goal | `<goalId>@<period>` | goal:completed: `goals[goalId]`, else `goals.daily` / `goals.weekly` |
| level | the level | xp:levelUp: `levels[n]` for every level passed |
| season | `champion:<id>` / `top10:<id>` | season:ended: every officer of the champion department with a counted run row in the season; the top 10 |

- Who: each participant of a completed non-test run who met the presence share. A flagged participant or run: every
  reward of the row is `held`.
- Rolls: `U.rng(hash('<run id>:<citizenid>:item-rewards'))` (a second settle rolls the same; the unique key stores
  nothing twice); each roll draws hit, pick and count. Chance = entry.chance + tierChance[pay tier] + min(findBonus ×
  the run's finds (every participant's `evidence`), findBonusMax), clamped to [0, 1]. The entry: byMission, else
  byType, else examplePools with `useExamplePools`.
- Caps per officer per reset day, every source together, forfeited not counted: `dailyItemCap` and `dailyValueCap`
  (count × configured value); past a cap nothing is given (0 = no cap).
- Validation (3 s after start, on first use, once ox_inventory is up, and on every `settings:changed` of `Rewards.*`): a
  forbidden name (armour, bandage, ammo-\*, weapon_\*, money, black_money, cash, and `Config.Rewards.forbidden` with `*`
  wildcards; case-insensitive) or an item ox_inventory does not know is turned off with a warning and a Config health
  line; `Usable()` checks `forbidden()` again at give time. `checkSetting(path, value)` is the Settings validator of
  `Rewards` (pool shape, chance 0–1, rolls 0–10, count 1–100 or `{ lo, hi }`, weight > 0, value ≥ 0).
- Status: `held` → `pending` (the locker) → `giving` → `given`; `forfeited`; given and forfeited are final. Delivery:
  claim (`UPDATE ... SET status = 'giving' WHERE id = ? AND status = 'pending'`), CanCarryItem, `AddItem(src, item,
  count, { cpReward = <row id> })` (never cpItem, so the mission-item sweep leaves it alone). No room → back to pending
  with one toast; in the arena or offline nothing is called; retried on officer:loaded and 10 s after arena:exited;
  never dropped in the world. A row left `giving` is never retried automatically (listed as Stuck). Delivery and the
  forfeiture job wait during maintenance.
- row:approved: held → pending → given; row:voided: pending → held; row:forfeited: held/pending → forfeited. Its own
  10-minute job (holding the busy lock `rewardForfeiture`) forfeits the held rewards of a voided row whose dispute window
  closed with no open dispute (CP.Cash fires row:forfeited only when cash was held). `undoForfeit(rowId)` on
  `row:forfeitUndone` (once; ones an admin cancelled or took back stay).
- History: every status change writes `breakdown.items` (`{ name, label, count, status }`, giving shows as pending)
  with `JSON_SET` on that path only; `result.items` leaves forfeited out.
- API: `lockerCount(citizenid)` (30 s cache; home:extras `rewardsWaiting`), `forRow(rowId)`, `deliver(citizenid)`,
  `locker(src)` (canClaim false with `rewards.reason.off|arena|inventory`), `claim(src, id)`, `validate()`,
  `forbidden(name)`, `health()` (registered as `rewards`), `entryFor`, `chanceFor`, `roll`, `expected(entry)`,
  `itemChoices()`, `adminView({ page, citizenid, status, source, from, to })`.
- Admin tools (§8.4.4): `checkInventory(id)` (Search for `cpReward = id`, then only slots whose own metadata has it:
  Search matches values and ignores keys; online only), `resolve(id, 'given'|'locker', audit)` (`err.reward_found` when
  the item is there), `cancel(id)`, `takeBack(id, audit)` (exactly the tagged slots, each with its own metadata,
  because ox_inventory adds keys when it gives; refused and undone when not all there).
- Net: callback `getRewardsLocker`, action `server:rewards:claim { id }` (2/s), callback `admin:getRewards`
  (openAdmin), push `rewards` whenever the locker changes.

### 5.34 CP.ConfigHealth — modules/confighealth
`register(name, fn -> { { level = 'ok'|'warn'|'error', text } })` (a second register replaces it), `run() ->
ConfigHealthItem[]` (errors first; a failing check is one error line). Runs 5 s after start (it registers CP.Rewards' `health` then; only that first run
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

### 5.35 CP.Diag — modules/diag (client)
No Crimson-Police state may outlive a run or a downed follow-up (the safety nets of §5.4, §5.15 and the web's
`QuietBoundary`, §9.1); this command says what holds the screen.
- F8 `CrimsonPoliceState`: four `[crimson-police:diag]` lines with the screen fade, NUI focus, scripted camera, pause
  menu, control, frozen, dead/last stand, vehicle, then what Crimson-Police holds (tablet, panel focus, test panel
  focus `'controls'|'invites'`, pick-up, run). `CrimsonPoliceState unstick` closes our tablet, releases our and the
  test panel's focus, runs `CP.Downed.restore`, then `SetNuiFocus(false, false)` (FiveM keeps one focus vote per
  resource, so this never touches another resource's). `state()`, `unstick()`.
- Admin UI → Officers → Support: `client:diagUnstick` runs `unstick()`; `client:diagState (token)` answers
  `server:diagState (token, state())` (only the asked player's answer, known keys only).
- Lint FX10 (`tools/lint_fivem.py`, `tools/lua_flow.py`, a Lua 5.4 parser with flow analysis): a while/repeat loop that
  can go round with no Wait while waiting on game state, or an ipairs loop that appends to its own table; checked by
  `tests/freeze_spec.lua` on `tests/fixtures/lint/fx10_loops.lua`.

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
- Simple set (A7): `COMMON` lists about 25 everyday paths (Debug, Locale, the tablet key, NPC accuracy and damage,
  the Flee times, spawning distances, the route line, Radio Silence, mission calls, the Builder minimums, payout
  reasons, built-in editing, the test overlay, the resets); each has `settings.label.<path>` and `settings.help.<path>`
  (the help also fills an empty config.lua description). `GROUPS` folds every section into 8 plain groups (tablet,
  missions, npcs, pay, points, police, dispatch, server; titles `settings.group.<key>`, help
  `settings.group_help.<key>`; a section no group names goes under server). The entry and `SettingView` carry
  `common` and `help`, a schema section and `SettingsView.sections[]` carry `group`, and `SettingsView` carries
  `groups` (`plainGroups()`: key, title, help, section keys) and `common` (`commonPaths()`).
- Simple view (A8): `SettingsView.view` is `Config.AdminUi.settingsView` ('simple' or 'all'; anything else =
  'simple'), the view `admin/screens/Settings.tsx` opens in until the admin picks one with the Simple / All settings
  switch. Simple (`simpleGroups()`) renders the `common` paths in order under their section's plain group, with
  `help` over `desc`, no `Config.<path>` line and no file name; a search or a filter still looks through every
  setting. In Simple, `MissionTweaks` and `DisabledLocations` (`PER_MISSION`) show a note and a button to
  `admin_missions` (tab catalog) instead of the JSON editor.
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

Full admin control:
- Locked also: `Tablet.title`, `Tablet.command`, `Tablet.adminCommand` (`settings.locked.names`),
  `Calls.npcCallPrefix`, `Calls.ownRunCallPrefixes` (`settings.locked.call_ids`), `Bonuses.*.each|block|engineOnly`
  (`settings.locked.code_fact`). A saved row of a locked path is ignored at boot and can still be reset.
- RANGES for Hard rules 15-18: `Calls.dodgeWindow` 10-300, `respondingExpiry` 60-7200, `Alerts.backstopRadius`
  50-1000, `backstopDelay` 0-10, `Downed.pickupDelay` 5-120, `checkEvery` 1-10, `Route.abandonAfter` 10-120,
  `maxDeviation` 30-500, `reportTimeout` 5-60, `maxDrift` 200-5000, `lateArriveRange` 0-500,
  `followActionSeconds` 0-1800; and for
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

Full admin control, System:
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
- Net: `server:admin:revertSetting`, `admin:exportSettings`, `admin:previewSettingsImport`,
  `server:admin:importSettings` (§8.4.5).

### 5.37 CP.AdminKit and CP.Maintenance — modules/adminkit (S)

The one wrapper every new admin action of full admin control goes through, and the maintenance lock. fxmanifest lists
the file by name (so it loads before every module) and again through `modules/**/server.lua`; FXServer runs both, so
the file starts with a load guard (`CP.AdminKit._installed`, as CP.Storage) and the second run changes nothing. Hook names the
packages share: `admin:changed { kind, citizenid?, missionId? }` (each module clears the caches it owns),
`row:voided`, `row:restored`, `row:forfeitUndone` (fired by the corrections package, §5.38), `settings:changed (paths)`,
`deptControls:changed { dept, key }` (a Mission control was set or reset, §5.49),
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

**`Kit.supAction(name, permKey, fn, opts)`** registers an action supervisors may use too, with the same
guards, ctx and order as `Kit.action` except P: `CP.Permissions.can(src, permKey, { department = opts.department(payload) })`
(admins always; a supervisor needs his `Config.Permissions.supervisor[permKey]` and, when a department is named, his
own department, else `err.other_department`), or `opts.permission(src, payload) -> ok, errKey` when the action decides
itself. A supervisor is never probed (§5.4); his `ctx.role` is `'supervisor'` and `ctx.audit` (and
`Kit.auditSync(..., { role = 'supervisor' })`) writes the audit row with that role.

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
runUuid)` (an officer of the run, or a real suspect of its case), `Kit.claimRequest / finishRequest / releaseRequest`, `Kit.validRequestId`, `Kit.uuid()`, `Kit.auditSync(src,
category, action, target, old, new, reason, opts)`, `Kit.changed`, `Kit.notify`.

**Day counts from saved rows** (a restart never resets a limit): `Kit.dayStart(ts)`, `Kit.weekStart(ts)` (CP.Schedule's),
`Kit.dailyCount(action, { target, actor, since }) -> n` (cp_audit rows since the daily reset), `Kit.dailySum({
missionIds = { 'manual_adjust' }, actor, column = 'final_points'|'cash_base', since }) -> n` (today's unvoided manual
rows by `breakdown.by`, absolute values summed in Lua).

**J: bulk jobs.** `Kit.registerJob(kind, { batch = fn(job, ids) -> ok, err; finish = fn(job); rollback = fn(job) })`;
`Kit.startJob({ kind, src, reason, ids, filter, detail, id?, wait? }) -> ok, jobId | false, err.admin_busy|job_kind`:
one job server-wide (it takes the busy lock), `cp_admin_jobs` row first (`detail.ids` = the fixed id list), batches
of 50 ids with `Wait(0)` between, `done` saved after every batch and `adminjob` pushed to admin players only
(`CP.Tablet.pushAdmins`): the start and every end state at once, a running update at most every
`Config.AdminControl.jobProgressEveryMs` (500; 0 = after every batch; the `adminjob:progress` hook follows the same
rule). The Corrections tab refetches on a running update at most once a second. `Kit.job(id)`, `Kit.jobs({ kind, limit })`. At start (5 s after load, once the
migrations are ready) a job left `running` is finished from `done` when its kind is registered, else rolled back
(`rollback`) or marked `failed`; admins get a toast. Per-officer effects are recomputed from rows in `finish`, never
applied as deltas.

**The busy lock** (one long piece of work at a time: a job, a storage copy, a backup, a restore): `Kit.busy() -> kind,
info, since`, `Kit.lock(kind, info) -> ok | false, err.admin_busy`, `Kit.unlock(kind)`, `Kit.withLock(kind, fn, info)`,
`Kit.waitIdle(ms) -> free` (the nightly archive and the forfeiture job wait on it). `Admin.storageCopy` takes it.

**SQL in files mode** (every statement): no ORDER BY/LIMIT on a UNION (wrap it in a derived table), no
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
  `pending` once and fires `row:forfeitUndone` (which brings back their item rewards).
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
  `index.json` and each manifest go through `CP.Storage.MemSQL.replaceFile` (`.tmp`, then a rename; plain `fs.write`
  where it is missing); a failed index save fails the backup. A missing or unreadable `index.json` is rebuilt from the
  `*.manifest.json` files (`fs.list`) and saved again, with one console line.
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

How hard armed mission NPCs fight back (Config.NpcCombat). Config is read at every
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
  its older name, counts while the new key is missing; false = set at the start and after a respawn only): they
  are one value per game, and another script (Crimson-Contracts' guard scaling) may set or reset it mid-run. `settings:changed` applies a mid-run change at once. A
  foreign `crimsonArena` value of the local player (docs/INTEGRATIONS.md, Crimson-Arena rule 8) stops it at once, before the server
  ends the run for that player. Start data with `npcCombat = false` (`CP.Runs.create` opts.npcCombat = false, for the live case's
  live runs; `run.npcCombat` is then false) starts nothing; with the field missing it starts them as usual.
- Client `drop(runId)` and the event `client:npcCombatDrop` (runId): for the active run only, `noCriticalHits` and
  `officerDefense` go back exactly as `stop` puts them back (the ped's own flag 2, the defense modifier read before the
  run) and `a.dropped` keeps them off for the rest of that run (`settings:changed`, a respawn); `aiDamage` and
  `aiMeleeDamage` stay (they act on NPCs only). Idempotent; the next `start` builds a fresh state (protection on again).
- Server (modules/npccombat/server.lua): `dropFor(run, src, why)` sends `client:npcCombatDrop` once per run and
  active participant (logged; false for a run with `npcCombat == false`, an ended run or a non-participant); the memory
  goes at `participant:left` and `run:ended`. Volunteer matching calls it for every participant when a volunteer's case is engaged
  (unless `Config.RealSuspects.npcCombat`). A `weaponDamageEvent` handler, always registered and read-only (never
  cancels), returns at once unless `Config.NpcCombat.playerHitDropsProtection == true` (shipped false, read on every
  event): the damage of a player (not an NPC the sender's game moves, as CP.Npc's `ShooterOf`) who is not an active
  participant of the victim's run, on a player ped (`IsPedAPlayer`, owner = `NetworkGetEntityOwner`) who is an active
  participant of an NPC run (not a test, no `run.realSuspect`, `npcCombat ~= false`) -> `dropFor(run, victim)`.
- The `crimsonPoliceRun` player bag (replicated, exactly `true`): `CP.Runs.create` calls `runStarted(run, src, on)`
  right after each `client:start`, and `on` (start data without `npcCombat = false`) sets it; it is cleared (`nil`) at
  `participant:left` (any reason, a disconnect included), `run:ended` and resource stop. Written only on a change
  (`flagRun(src)` names the run it was set for). Crimson-Contracts (its `onCrimsonPoliceRun`) leaves the
  shared AI damage value alone while it is true (or while our `crimsonArena` flag is on), so the two scripts never set
  it against each other once a second on a run that has no `crimsonArena` flag (before arrival, after
  `CP.Alerts.releaseRun`). docs/INTEGRATIONS.md, Crimson-Contracts.

### 5.43 CP.Spawn — modules/spawn (client, server)

What an officer's game can see of the spawn director's points (`Config.Spawning.preferHidden`, §5.10), the ground probe
of one point (`Config.Spawning.ground`), and the placer that puts a new mission entity on the ground when the server
asks (`Config.Spawning.place`), so nothing spawns in front of the officers or in the ground.

#### Client
- `visible(points, budgetMs) -> { boolean }` (at most 32 points) — `false` when every line from the officer's eyes (head
  bone 31086 and `GetFinalRenderedCamCoord`) to 1.0 m and 1.7 m over the point hits something (`StartShapeTestLosProbe`
  flags 1 + 2 + 16, options 7, his car or ped ignored); anything unknown (a probe not started, an invalid result, out
  of budget (50–5000 ms), no point) is `true`. At most 16 probes at once; unfinished ones are drained so the game frees
  them. Callback `client:spawn:visible` (`{ points, ms }`; `{}` on bad args or an error).
- `walkIn(car, ring, budgetMs) -> { { x, y, z, hidden } }` (`Config.Spawning.contactRing`): where a returning driver or
  a thief appears for a car: in the direction he looks and 25/50/75° either side, at ring[1], halfway and ring[2] (5–100
  m), `GetSafeCoordForPed` (no interior, no water), kept when within the ring, ring[1]+ from him, ≤ 90° off his view and
  2 m from others; hidden first, at most 8. Callback `client:spawn:walkIn` (`{ car, ring, ms }`).
- `probe(kind = 'ped'|'vehicle'|'prop', x, y, z, h, model, opts) -> result` (needs a thread), in order:
  1. collision loaded around `opts.entity` or his ped (`collisionTimeoutMs`, 500–30000);
  2. interior: not ready → pinned and waited for (`interiorTimeoutMs`); never ready → `interior_not_loaded` (it unpins
     only what it pinned);
  3. ground: `GetGroundZAndNormalFor_3dCoord` from z + 2.0 and z + 50.0 (a roof → `roofZ`); none → `no_ground`; with a
     surface over z + 0.1 a look from z + 0.1 finds the ground right under, and the point takes the one it needs the
     smaller move to;
  4. water → `in_water`;
  5. height: dz = z − groundZ inside the kind's range (`pedAbove` −0.3..1.6, `vehicleAbove` −0.2..1.5, `propAbove`
     −0.1..0.5) → `ok`; else `snap` when within `snapWithin` (3.0) of groundZ + lift (a person 1.0, a vehicle its model's
     −min.z, an object 0), else `underground` / `floating`;
  6. wall (people and vehicles that are ok or snap, unless `opts.wall == false`): a capsule on the ground (a person
     0.45–1.7 m r 0.32; a vehicle sized from its model) → `in_wall`; not finished = not known.
  `result = { status, kind, x, y, z (where to put it), groundZ, dz, normalZ, roofZ, interior, loaded, water, wall,
  sized, lift }`; a non-number coordinate answers `no_ground` at once.
- The placer: its own `AddStateBagChangeHandler('cp', ...)`. A bag of this player's run with `place = { x, y, z, h?,
  kind, token, from? }` (§6.2) and a token not taken yet starts one placement (a run's end forgets them). The entity
  must exist here within 3 s and this player must be active. The game that controls it places it; else the
  participant nearest the point. An entity already more than 3 m from the ask (and from `from`) was placed before:
  `'placed'` reason `'moved'`. Else it tells the server it checks (`server:spawnChecking`, once per token, and `done =
  true` when it gives up), takes one of 4 slots (waiting up to 30 s), asks control (2 s), freezes it, loads its
  collision, moves it to x, y first when it waits at `from`, and probes. Seated, attached or moved meanwhile: not moved,
  let go (not an object or a cuffed person). ok or snap: put at x, y, groundZ + lift (never another spot), vehicles and
  objects set on the ground, let go except objects and cuffed people: `'placed'`. Else frozen and `'bad'`. Answered once
  per token with `server:spawnPlaced (runId, { netId, token, result, reason, groundZ, dz, z })`.
- `holds(entity) -> bool` — true while its bag carries a `place` this game has not placed; CP.Npc's host never lets such
  a person go (§5.11), so a host with no ground loaded never drops him through the map.

#### Server
- `ask(run, netId, entity, kind, opts) -> place|nil` (from the engine's Track for every new entity): with `enabled` and
  `place` on and a point, `FreezeEntityPosition(entity, true)` (FXServer keeps the RPC for the first game that takes it),
  the ask `{ x, y, z, h, kind, token }` with up to 8 other points from `opts.alt`. `waiting(runId) -> n`,
  `holding(netId)` (field_contact walks a returning driver to his car only after it).
- A 1 s check while any ask is open: drops asks of ended runs or gone/dead entities; with place or enabled off lets every
  entity go; refreezes when the simulating game changes to one that is not an active participant's within
  `activateRange`. The time (`placeTimeoutMs`) runs only while a participant is within `activateRange` (staged entities
  wait without limit) and not while a participant's game said it checks (at most 34 s + the two load timeouts). Past
  it, `onTimeout = 'unfreeze'` (default) lets it go where it stands, `'delete'` counts it as gone and deletes it (never
  for an `again` ask); one `CP.warn`.
- `server:spawnPlaced` (30/s per player): only from an active participant, for an open ask with that net id and token.
  `'placed'` with z more than `snapWithin` + 2 m off is refused (warn); else `place` leaves the bag (`CP.Npc.setPlace`)
  and the entity is let go from here when needed. `'bad'` for a person now seated: over, let go. Other `'bad'`: while
  fewer than `Config.Spawning.retries` other points were tried, the next free point the director allows now
  (`Runs.choosePoints(run, free, 1, { obj })`) becomes the ask (a new token, `from` = where it waits; one `CP.warn` naming
  both points); else it is let go where it is (one warn).
- `again(run, netId, coords, from) -> place|nil` — the server moved a live person or vehicle itself (a warrant suspect
  at the door, the prisoner van on its point): freezes it and replaces any ask with one at `coords` (no other points; a
  bad answer lets it go).

### 5.44 CP.Markers — modules/markers (client)

The current objective on this officer's map (`Config.Markers`): one pointer per officer (a blip, or a circle with its
centre) and at most one GPS line. modules/runs/client.lua drives it: `client:objective start` → `set(runId, index,
msg.marker, ctx)` after the block's `start`; `client:marker` → `update` (the current started objective only); `stop` →
`clear(runId, index)` before the block's stop; every cleanup → `clear()` (also removes service vehicles).
- The marker (§5.10 `marker`; nil = none): `{ kind = 'point'|'area'|'targets', look, label, key, number, coords, radius,
  route = true|false|'block', targets = { { key, netId, x, y, z, look, label, variant, number, beyond } } }`. `look` is
  a `Config.Markers.kinds` key (default `objective`, an area `searchArea`); `variant` `boss|next|followUp|setback|
  surrendered` picks the kind's bossScale, nextScale, followUpColour, setbackColour or surrenderedScale (0.6 by default).
  `beyond`: this target takes the line while the officer is farther than that from it (until within 75 %), never
  closer (escort: the truck while he is beyond clearRadius, else the destination). `route = false`: no line; `'block'`:
  the block keeps its own line (checkpoint_route). At most 32 targets.
- One icon per target: `adopt(key, blip)` — a block hands over the blip it draws for target `key`: that blip is the
  pointer (CP.Markers sets only its line, priority and one flash); `release(key, blip?)` takes it back (line off,
  CP.Markers draws the target again). Blocks that hand over: interact_points (numbered points, the hidden search's
  centre `'area'`), skill_check (devices `'d<n>'`, named after `obj.target.label`, else `block.skill_check.blip`; a
  set-back device flashes until fixed), process_scene (`'scene'`), checkpoint_route (`'cp<n>'`, the next at nextScale,
  its own line in `routeColour()` while `canRoute` allows), pursuit (cars, suspects on foot; the observe violator only
  once it passed), escort (the truck, `'dest'`), flee_arrest (`'door'` before the knock, people by net id),
  protect_rescue (hostages, `'safe'`), field_contact (cars and people), search_area (`'center'` with its circle,
  `'c<n>'` clues, fugitives). People switch between kinds suspect / fleeing / surrenderedScale and are restyled in
  place. CP.Markers draws its own icon only for a hostile_waves fight area (`kinds.fightArea`, "Hostiles"), a fallback
  anchor, a target not streamed here, and service vehicles; detail blips never handed over (hostiles, the boss at
  bossScale) are still styled with `style`.
- Own icons: `AddBlipForCoord` (an area adds `AddBlipForRadius` at `areaAlpha`); a target `AddBlipForEntity` while it
  exists here, else (`farTargets`) a coord blip at the server's position, swapped as it streams. Unchanged elements keep
  their blip, line and flash.
- `style(blip, kind, label, opts)` — sprite, colour, scale, `shortRange`, `category`, `ShowNumberOnBlip`, the name;
  `variant = 'setback'` flashes with no timer while `setbackFlash`. The pointer gets `SetBlipPriority(12)` and one flash
  of `flashSeconds`. `styleArea(blip, kind)` (a block's own circle), `routeColour()` (`Config.Markers.routeColour`, 0–85,
  default 5: every Crimson-Police line).
- The line: on one blip, the one the pointer leads to (the point or centre, or the nearest target, moved when another is
  25 % closer; a `beyond` target first), `SetBlipRoute` in `routeColour`; off within `routeOffWithin` and inside an
  area. `canRoute(ctx)` false while `enabled` or `route` is off, under Radio Silence, while CP.Route is still driving to
  the start, or while the officer has a waypoint. `leads(ctx)` — whether an objective line can show for that run (CP.Runs
  asks before a late partner's game drops the start, §5.12).
- HUD line (`Config.Markers.hudLine`): `CP.Tablet.hud({ target = { label, distance, inside? } })` for what the pointer
  leads to (10 m steps under 1 km, 100 m above), on change only; `{ target = false }` when there is none (Radio Silence
  included), on the way to the start, off, and at every `clear`. Shown under the objectives (§9.3).
- `objectiveGps()` — client action `setObjectiveGps`: `SetNewWaypoint` on the pointer's target (its line off, toast
  `markers.gps_set`); `err.objective_gps_off|none|start|silence`. While the waypoint stays ours it follows the pointer
  once it is 50 m off; `clear` and another objective remove it; a waypoint the officer set himself is never touched.
- Officer options (`shared/options_map.lua`): `objectiveGps` (server enum, `'route'`): `'waypoint'` = no line and a
  waypoint at each new pointer where a line could go (never over his own); `'off'` = no line, no waypoint, `leads` false.
  `hudTargetLine` (local, true). `colourblindMap` (local, false): `colour(role, fallback)` gives fixed colours per role
  (start 5, objective 5, target 17, hostile 27, friendly 3, area 0) to `style`, `styleArea`, own circles and
  `routeColour()`.
- `hidden(ctx, kind, variant?)` — whether Radio Silence (`Config.Markers.radioSilence`; unknown = `'area'`) hides a
  block's blip of `kind` (or `'route'`); every block client asks before drawing. `'none'` hides everything but start,
  prisonerVan and towTruck; `'area'` (shipped) hides `'route'`, the `'next'` variant, `point` and `device`, and every
  kind but the objective's circle or one point (start, checkpoint, searchArea, fightArea, destination, safePoint, scene,
  objective, service vehicles); `'full'` hides nothing. CP.Markers' own pointer under `'area'` hides every target with a
  net id and shows only the nearest of several points; with `radioSilenceLastKnown` > 0 a hidden moving target gets a
  200 m `markers.last_known` circle, moved every that many seconds. search_area keeps its circle as the pointer.
- `service(key, spec)` — a prisoner van or tow truck coming to this officer (`spec = { netId, coords, kind =
  'prisonerVan'|'towTruck', label }`, nil removes): shown in every Radio Silence mode while `serviceVehicles` is on,
  never routed. modules/custody/client.lua calls it from `client:serviceBlip` (key `service:<id>`); the server
  (`SyncBlip` in its 1 s tick) sends it on each status change (coming, parked, loading; off once it leaves), and
  `run:arrived` sends the ones on the map to a late partner. The coroner van stays unmarked.
- One 1 s check loop only while something is on the map (streaming swaps, adopted blips, nearest target, line, HUD
  line, the waypoint). No entity pool scans.

### 5.45 CP.Opponents — modules/opponents (S)

The real suspects of a case, shared by live crimes (§5.46) and volunteer suspects (§5.47). A case belongs to one run
and one objective; each suspect is keyed by citizenid and carries his state (free, cuffed, detained, booked, lost, left
or void), the server proof that decides every detain and booking, the officers' conduct ledger, the identity and pair
rules, a position trail and a timeline for review, and staff notes that never hold points. Nothing runs while
`Config.LiveCrime.enabled` and `Config.Volunteers.enabled` are false (both shipped false). Rules:
`Config.RealSuspects`. Record times are GetGameTimer() ms; `t` in the timeline, notes and trail and
`case.openedAt` / `closedAt` are os.time() seconds.

#### Core (modules/opponents/server.lua)
- `case = { runId, run, kind = 'live'|'volunteer', index, openedAt, openedMs, scene, lostRule, meet, suspects = { [cid]
  = rec }, order, timeline, ledger, trail, notes, crimeEndedAt }`; `rec` holds cid, src, license, `label` ('A', 'B', ...
  shuffled with the run seed), state and its times, `md` (the metadata mirror: ishandcuffed, isdead, inlaststand,
  injail), down, protectUntil, cuff, outsideCuff, jail, share, caughtBy, armedUntil, everArmed, hit times, conduct, afk,
  near, dropAt, leftAt, byLeave, notes, outcome.
- `open(run, { kind, index, members, scene, lostRule, meet }) -> case|nil` — `members` a list of citizenids or a map
  keyed by them (server ids in it are never read). Each src from `CP.Qbx.getByCitizenId` and one `getInfo` at open; an
  offline suspect starts in the disconnect grace; a suspect of another case is left out; a second open returns the
  case.
- `close(run) -> { [cid] = outcome }, case` — 'detained', 'booked', 'got_away' (free, cuffed with no detain, lost),
  'left', 'void', or one a later step set. A leave still in its grace is made final first, so logging off before the
  end is never 'got_away' by the leave. The `run:ended` hook closes the case; the last `casesKept` (16, 1–200) closed
  cases are kept.
- `active()` (true while a case is open; the sc-police facts pass only then), `caseOf(run)`, `bySrc(src)`,
  `byCid(cid)`, `view(run)` (for blocks, no server ids: label, state, online, contact, down, afk, share, byLeave,
  everArmed, outcome, md), `nearAny(run, coords, range) -> true, cid, metres` (last watch pass, no native read),
  `crimeEnded(run)`, `noteArmed(cid)`, `trailOf(run, cid)`, `setState(run, cid, state, { event, why, by })`,
  `send(run, cid, kind, extra)` (opp_down, opp_up, opp_cuff_attempt), `timeline(run, entry)`, `onTick(fn)`, and the
  proof step's `onMeta` / `onClose`.
- `eligible(src, opts) -> ok, reason` (events and claims only), refused in this order: `not_loaded`, `in_case`,
  `instance` (bucket ≠ 0), `arena_flag`, `on_duty` (a Config.Departments job), `job_hop` (`lastPoliceAt` within
  `jobHopMinutes`), `afk`; with `opts.intake` also `no_position`, `no_start_zone`, `down`, `cuffed`, `jailed`; then
  `excluded` (`IsPlayerAceAllowed(src, excludeAce)`) and `admin` (while `excludeAdmins` is not false).
- `note(run, reason, detail, cid)` — the case's, the suspect's and the timeline's note plus `CP.AntiCheat.note`
  (audited `runNoted` once per reason and suspect, never a flag). Everything a suspect does himself is a note:
  `rs_combat_log`, `rs_evade_instance`, `rs_fake_arena_flag`, `rs_teleport`, `rs_went_on_duty` here.
- `sampleCrew(key, cids)` / `unsampleCrew(key, cids?)` — AFK samples for citizenids with no case yet.
- Event-kept maps: `srcOf[cid]` / `cidOf[src]` for tracked citizenids only (set at open, `sampleCrew`, player load;
  cleared on unload and drop, so a reused server id never matches); `rec.md` seeded by getInfo and kept by
  `CP.Qbx.onMetaDataChange`. A suspect going on duty in a department job: free or cuffed → void and `rs_went_on_duty`.
  Another script's crimsonArena flag in bucket 0 is `rs_fake_arena_flag` once (he stays tracked).
- The watch: one 1 s thread while a case or crew exists. Per pass: the participants' coords once, and per suspect only
  `GetPlayerRoutingBucket`, `GetPlayerPed`, `GetEntityCoords` (and the camera on an AFK sample), never a Qbox export.
  - A bucket ≠ 0 is leaving: cuffed → detained, free → the onLeave rule, detained and booked stay; note
    `rs_evade_instance`.
  - A move faster than `Config.AntiCheat.maxSpeed` is `rs_teleport` (not right after a rejoin or an instance).
  - Contact: a participant within `contactRange` (`opp_contact` once). Lost (with `case.lostRule`): a free suspect after
    contact or `crimeEnded` with no participant within `range` for `seconds`.
  - Trail: a point every `trail.every` s, at most `trail.max` (a ring). AFK: a sample every `afkSampleEvery` s (moved
    under 1 m and turned under 2° since the stillness began, AFK after `afkSeconds`), only for free suspects who are not
    down and sampled crews.
- Leaving (`playerDropped`, unload): cuffed → detained at the drop; a logout or character switch is final at once, any
  other drop waits `disconnectGrace` s. Final: cuffed → detained, free → `Config.RealSuspects.onLeave` ('void' → left,
  'caught' → detained with `byLeave` and share 1 (0 when AFK), 'escaped' → lost), detained and booked stay; always
  `rs_combat_log` (left within N s of contact, contact N s ago, no contact, offline at open). A rejoin within the grace
  keeps the record; one who left cuffed or detained and returns within `reconnectNoticeMinutes` makes the case's
  officers get `opp.back_in_city` (no name).
- Every state change goes to the timeline and, while the run is in progress, `CP.Runs.dispatch(run, case.index, nil,
  { type = 'opp_<state>' ('opp_released' for free), cid, label, prev, by, share, why })` (server-only types, §5.10).
  Opponents are never in `run.entities`, CP.Npc's registry or a `cp` bag. Resource stop clears everything.

#### Proof (modules/opponents/proof/server.lua)
Inputs: the `CP.ScPolice.on` facts (cuff, uncuff, cuffBreak, bobbyPin, escort, jail), `CP.Ambulance.on('respawn')`,
the metadata mirror (ignored in a bucket ≠ 0, where Crimson-Arena rewrites cuffs and downs) and the watch. Nothing here
flags: a suspect's own acts are notes.
- Cuff pair: a 'cuff' by an active participant of a live run also gives `CP.LiveCrime.cuffHint` (staff line naming the
  officer, at most one per 10 s). On a free suspect the attempt is kept when the officer is on duty in a turned-on
  department job (read from `getInfo`, never `getOfficer`: a listener must not yield), both are in bucket 0, the
  officer is not in the arena, and the server distance is within `cuffRange`: a participant's as `rec.cuff`
  (`cuff_attempt`), an outside officer's as `rec.outsideCuff`; a refused participant attempt is the line
  `cuff_refused`. `ishandcuffed` false → true within `cuffPairWindow` of `rec.cuff` → `cuffed` with `share` 0 and note
  `rs_afk_catch` when AFK, `neutralisedShare` when down (or after an in-contact respawn), else 1. Within the window of
  an outside cuff: `Config.RealSuspects.outsideCuff = 'assist'` (shipped) = cuffed for the case while a participant is
  within `contactRange`, else stopped; `'stopped'` = outcome `stopped`, state void, note `rs_outside_cuff`; in a live
  case the outsider gets `CP.LiveCrime.offer(run, src, 'cuff')`. No pair → the line `cuffed_unproven`.
- Hold: a cuffed suspect still cuffed after `custodyHoldSeconds` → `detained` (`custody_hold`), once; detained and booked
  never go back. Refused while `rec.protectUntil` lasts (`spawn_protected`, back to free). An on-duty participant's
  'escort' of a downed free suspect → `detained` (`escort_down`) at `neutralisedShare`.
- Getting free during the hold is explained by a participant's 'uncuff' within 5 s (`released`), a 'bobbyPin' success
  within 5 s from a plausible rescuer (not the suspect, not cuffed or down, bucket 0, near him on 2+ passes, the case's
  first rescue of him: `rescued`), or his own 'cuffBreak' within 5 s between 2 s and `breakFreeSeconds` after the cuff
  (his first: `broke_free`) — each back to free. An unexplained release waits 2 s; anything else is a self-uncuff →
  `detained` (`self_uncuff`, note `rs_self_uncuff`); an outsider's uncuff within 5 s makes it `outside_uncuff` with
  note `rs_outside_uncuff`. Rescue candidates (`rec.near`, players within `rescueRange`) are read only while a suspect
  is cuffed.
- Down: `isdead`/`inlaststand` true → `rec.down` (`opp_down`, with who was near), both false → up (`opp_up`).
- Booking, matched in either order within 10 s: the injail rise and a 'jail' by an on-duty participant within
  `jailRange` of a detained suspect (`inZone` = inside one of `bookingZones`, `{}` = anywhere) → `booked` with
  `min(jailTime, jailTimeMax)` when ≥ `minJailTime` and in zone, else `booking_too_short` / `booked_outside_station`. A
  participant jail that cannot be a booking is `jail_refused`. An outsider's jail of a free or cuffed suspect → outcome
  `stopped` and note `rs_outside_jail`. sc-police's prison exports are never called.
- Hospital: a respawn while not down (or up for 5 s+), or after less than `earlyRespawnSeconds` down → void and note
  `rs_early_respawn`. Otherwise `protectUntil = now + spawnProtectSeconds`, unless a participant was within
  `contactRange` at the down and is again at the respawn (no protection; his next cuff scores at `neutralisedShare`).

#### Conduct (modules/opponents/conduct/server.lua)
How officers treat a real suspect, from server facts only. Every flag is an officer-conduct flag on the officer who
fired, drove or seized (`CP.AntiCheat.flag(run, officerSrc, ...)`: only his points are held); nothing ends a run or
cancels an event; a supervisor's void in Review is the "Failed".
- Armed: the watch reads each tracked suspect's `GetSelectedPedWeapon`; a weapon not unarmed and not in
  `Config.RealSuspects.lessLethal` sets `armedUntil = now + armedMemory` and `everArmed` (also his hit on a participant
  and `Opp.noteArmed`). `Opp.armedState(cid) -> armedNow, everArmed`.
- The ledger: a third read-only `weaponDamageEvent` listener, returning at once while no case is open and reading
  nothing for senders who are neither suspects nor participants with a case. A hit is blamed only on its sender
  (damage from an NPC he simulates is nobody's); victims are player peds in bucket 0. Participant → his suspect (dir
  officer) and suspect → a participant (dir suspect) go into `case.ledger` (the same sender, victim and weapon within 2 s
  adds to the last line; at most `damageLogMax` lines).
- A participant's hit on his suspect, in order: (1) the suspect is in custody (CP's proven cuffed or detained AND the
  cuffs mirror; a suspect who freed himself is not), detained and down for more than `downGrace`, or down for more than
  `downGrace` after an earlier hit by the case's officers → flag `rs_excessive_force`; (2) a lethal shot on a suspect
  never armed → penalty and flag `rs_unarmed_shot`; (3) run over or rammed while on foot → penalty `rs_ran_over` and
  flag `rs_vdm`. Each once per officer per suspect. `rs_unarmed_shot` and `rs_ran_over` are engine-only pct penalties
  (−0.25 each, `each`).
- Cash seizures (`CP.ScPolice.on('seizeCash')`, only on-duty `leo` jobs count): every attempt by a participant of a run
  with a case, or on a suspect, is audited (`seizeCash`, own_suspect|other_case|not_suspect); one on a suspect not
  under arrest (CP's proven states) or from more than 3 m → flag `rs_bad_seize` on a participant, a staff note for an
  outsider.

#### Identity and pairs (modules/opponents/pairs/server.lua, table `cp_pvp_pairs`, migration 009)
The anti-farm core both features share. Every answer is a memory lookup; the ledger is read once at start and every
write goes to the database in a thread.
- `selfBlock(officerSrc, suspects) -> blocked, kind, flags, match`, per suspect in order: `own_character` (one of
  `CP.Access.selfCitizenids`), `own_license` (his licenses and their Qbox users rows hold the suspect's; strict: an
  unknown license refuses), and with both online every identifier and token compared whole by kind: a shared kind in
  `identityMatch.block` → `linked_account`, in `identityMatch.flag` (ip, token) → not blocked with `flags = {
  'rs_linked_accounts' }` (the caller flags that officer). `match = { cid, kinds }`; identifiers are never stored,
  logged or sent. Characters and licenses are cached per officer session.
- Duty maps (kept by duty/job/load/unload/drop events): `dutySince(cid)`, `lastPoliceAt(cid)`, `lastSuspectAt(cid)`; a
  `duty_off` row is written whenever someone leaves police duty while a feature is on, so a restart keeps the job-hop
  history.
- The ledger rows: kind `live` | `volunteer` (one per officer and suspect of a closed case), `block`, `exclude`
  (officer ''), `suspend` (suspect ''), `duty_off`. `recordPairs(run, rows)` at the close (one INSERT in a thread). At
  start the rows of the longest window in use and every running admin row are read.
- Caps: `pairOk(officerCid, suspectCid) -> ok, reason, until` (`blocked`, `pair_cooldown` (a scored case within
  `pairCooldownHours`), `suspect_cooldown` (any case within `suspectCooldownMinutes`); `gone` rows never count),
  `suspectDayCount(cid)` (`maxCatchesPerSuspectDay`), `officerDayCount(cid, kind?)`, `excluded(cid)`,
  `suspended(cid)`, and the admin writers `block`, `exclude`, `suspend` (0 < days ≤ 3650).
- Pair repeat: `checkPairFlags(run)` after recordPairs: the pair's cases within `pairFlag.days` reach `pairFlag.count`
  and a second sign exists (a detain within `fastCatchSeconds`, a never-armed suspect who moved under 30 m after contact,
  or a case under 180 s) → flag `rs_pair_repeat` on that officer.
- Retention, at start and daily: `live`, `volunteer` and `duty_off` rows older than `pairLedgerDays` and ended admin
  rows are deleted.

#### Staff (modules/opponents/staff/server.lua, saved/server.lua)
Server-only (never on an officer's tablet). Timeline lines get the names fixed when written (`who`, `byWho`).
- `cases()`, `findCase(runId)`, `wasSuspect(cid, runId)`, `suspectOfRun(cid, runUuid) -> true|false|nil` (memory, then
  `cp_pvp_pairs`), `pairStats(cid?)` (at most 200 lines), `adminRows()`, `staffCases()`, `staffCase(runId)` (suspects
  with names, times from open to contact/cuff/detain/booking, the timeline as text, flag and note lines, the ledger by
  name; never a trail point).
- Closed cases are saved in `cp_pvp_cases` (migration 016) while `Config.RealSuspects.saveCases` (shipped true) and a
  feature are on: one row per case (`case_json = Opp.savedForm(case)`, plain values, never a position), written one
  frame after the close; the start prunes rows past `pairLedgerDays` and `casesKept` and restores them (marked
  `restored`). Open cases are not saved: a restart ends their runs.
- The self rule: `Kit.selfRun` and `P.canReviewRun` count a suspect of the run's case as taking part (fails closed).
- Admin (`antiFarmOverride`, §8.4.1): callbacks `admin:getRsCases`, `admin:getRsCase { runUuid }` (`err.own_run`,
  `err.rs_no_case`; latent), `admin:getRsPairs { citizenid? }`; actions `server:admin:rsBlockPair { officer, suspect,
  days, reason }`, `rsExclude` / `rsSuspend { citizenid, days, reason }`, `rsLift { kind, officer?, suspect?, reason }`
  (`Config.RealSuspects.staffLift`; `err.rs_no_row`), `rsClearStrikes { citizenid, reason }` (volunteers on and
  `Config.Volunteers.staffClearStrikes`; `err.rs_no_strikes`): a reason, never the admin's own characters
  (`err.self_target`), `err.rs_off` while both features are off, one per target per 10 s, audited. Names
  (`staffNames`) come from one batched lookup per call; weapon names from `CP.Weapons.label` (shared/weapons.lua;
  unknown = `#<hash>`).
- Admin UI → Real suspects (`admin/screens/RealSuspects.tsx`, key `admin_rs`, under More): shown with
  `antiFarmOverride` and `Session.config.realSuspects.screen` (a feature on and `Config.RealSuspects.adminScreen` not
  false). Tabs Cases (a drawer with the case) and Pairs and blocks; one tool dialog (`admin/components/realSuspects.ts`
  checks the inputs first).

### 5.46 CP.LiveCrime — modules/livecrime and modules/integrations/crimson_contracts (S)

Live crimes (`Config.LiveCrime`, `enabled` shipped false). The adapter listens to Crimson-Contracts' server-only
lifecycle events (AddEventHandler only, from the scripts in `Config.LiveCrime.sources`) and never requires that
resource; CP.LiveCrime turns a contract whose police alert went out into a red LIVE call on Dispatch, opens a
CP.Opponents case for the crew when a unit claims it (no draw: the engine-only `live_crime` mission with the
`live_response` block, §7.3), lets backup join, scores it with the live_* lines (points only unless the owner turns on
its money switches), and reports results through the export `GetAvailablePolice` and a server-only end event.

#### Intake
Crimson-Contracts sends these only with `ContractsConfig.LifecycleEvents = true` (shipped false):

| Event | Payload | Handler |
|---|---|---|
| `crimson-contracts:server:contractStarted` | `{ id, uid = '<id>_<start time>', key, label, locationLabel, coords, members = { [citizenid] = server id }, leaderCitizenId, startedAt, test }` | `onStarted` |
| `crimson-contracts:server:dispatchSent` | `{ id, uid, dispatchId = 'crimson_contract_<id>_<time>', title, street, coords }` (never for ATM alerts) | `onAlert` |
| `crimson-contracts:server:contractEnded` | `{ id, uid, outcome = 'completed'\|'failed'\|'cancelled', reason }` | `onEnded` |
| `crimson-contracts:server:memberRejoined` | `{ id, uid, citizenid, src }` | `onRejoined` |
| `crimson-contracts:server:crewShot` | `{ id, uid, citizenid, suppressed, trigger = 'shot'\|'gun_kill' }` | `onCrewShot` |

- Adapter (`CP.CrimsonContracts`, `CC.EVENTS`): the handlers are always registered (turning `enabled` on in Settings
  needs no restart) and return at once while it is off. `GetInvokingResource()` must be in `sources` (else dropped with
  one warning a minute); the payload must match the shapes (`id` whole, `uid` a name ≤ 32, keys ≤ 64, citizenids ≤ 50,
  1–16 members, finite coords; texts trimmed, control characters removed, cut to 64/64/50/100/128 bytes); anything
  else is dropped. Every server id in a payload is ignored (`members` keeps only its keys). The clean copy goes to
  `CP.LiveCrime.<fn>(resource, data)` in pcall.
- Records: `crimes['<resource>:<uid>']` in memory only (at most 200; pruned 1 h after the end or 2 h after a start
  with no end; a reporting resource that stops ends its crimes `stopped`). No timer.
- `onStarted`: a known uid is ignored; `test == true` (an admin's test contract) is a test record, audited
  `liveCrimeIgnored` (`test`), never sampled or reported; otherwise, while its key maps to a type,
  `CP.Opponents.sampleCrew` starts the crew's AFK samples.
- `onAlert` (once per crime): the key maps through `Config.LiveCrime.types` (an OPEN Settings table: contract key → a
  `Config.MissionTypes` key or false; off → `liveCrimeIgnored type_off`). Each member found online whose getInfo
  matches is a suspect when `CP.Opponents.eligible(src, { intake = true })` passes and he is within
  `Config.LiveCrime.suspectRadius` (300 m, 10–2000) of the crime. None → `liveCrimeIgnored no_suspect`. Else the
  record keeps suspects and the alert, the others stop being sampled, the audit `liveCrimeReported` (`<suspects>/<crew>`)
  is written and `LC.post(crime)` posts the LIVE call. Audit lines: category audit, actor console, target the crime
  key, no citizenid.
- `onEnded`: the open case's run gets `CP.Opponents.crimeEnded(run)`; samples stop; the LIVE call lapses
  (`CP.MissionCalls.endLive`). `onRejoined`: a timeline line. `onCrewShot`: `crime.armed[cid]` (copied into the case at
  open) and `CP.Opponents.noteArmed` for a running case's suspect (Crimson-Contracts reports at most one `shot` per
  contract and one `gun_kill` per guard, so the case's own weapon sample decides the rest).
- API: `LC.get(crimeKey)`, `LC.crimeOf(run)`, `LC.inCrew(cid) -> bool, crime` (false while off and for tests),
  `LC.post(crime)`.

#### The LIVE call
- `CP.MissionCalls.postLive(crime)` keeps the call in memory only (a negative id, code `LIVE-<n>`), type = the crime's
  mission type, area from its coords, priority 1, `offerEnds` = now + `Config.LiveCrime.offerTime` (300, 30–3600),
  `live = { crimeKey, title, street, coords, suspects }`. Refused (audited) while off, while `Config.MissionCalls.enabled
  == false`, for a second call of a crime, and at `Config.LiveCrime.maxLiveRuns` (2, 1–20) open or claimed LIVE calls.
- The toast (`client:missionCall` with `live = true`) goes to every member of an idle unit who has not muted calls and
  is not on a real call (favourites ignored), shown as a red "LIVE call". The card shows the distance to the reported
  place (never a suspect's), no cash, points or twists, locked for non-leaders. LIVE calls never count in open-call
  limits, `claimableCount` or `WithdrawAll`.

#### The claim and the case
- `MC.claim` of a LIVE call: `err.live_case_off` while off; twists dropped; `Draw.check(src, type, nil, { crimeKey })`
  and the call's rules, never a pool; `missionCall.staff = true` (no rapid response).
- CP.Draw's live path: every accept rule of a mission (leader, size, duty, arena, on a run, mission ban, types off,
  hourly/daily caps) except no server run caps (`maxLiveRuns` caps cases), the type cooldown only with
  `Config.LiveCrime.typeCooldown` (false), the operation lock only with `duringOperation = false` (shipped true), and
  `IsOnCall(src, except)` with `CP.Calls.exemptFor` of the case-to-be. Then `LC.claimCheck`. No twists or ready check
  unless `Config.LiveCrime.readyCheck` (false). `FinishAccept` runs `claimCheck` again, takes `LC.missionFor(crime)`
  and calls `CP.Runs.create` with `live = LC.liveOf(crime)` and `npcCombat = false`.
- `LC.claimCheck(crime, officers)` (memory only): `err.live_case_off`, `err.live_case_gone` (no, ended or test crime,
  or every suspect in another case), `err.mc_taken_by`, `err.live_case_suspect_used` (every free suspect at
  `maxCatchesPerSuspectDay`), then per officer `err.live_case_own_suspect` (crew member or `Opp.selfBlock`),
  `err.live_case_suspended`, `err.live_case_recent_suspect` (`lastSuspectAt` within `jobHopMinutes`), and per suspect
  `err.live_case_pair_blocked` / `err.live_case_pair_cooldown` (`Opp.pairOk`). A pair cap refuses the claim (another
  unit may take it) rather than scoring nothing.
- The engine mission: `LC.engineMission()` registers `live_crime` once with `CP.Missions.registerEngine` (one
  `live_response` objective, `cooldown = 0`, `vehiclePenalties = false`). `LC.missionFor(crime) -> def, 1`: the crime's
  type, label "Live case: <alert title>", `timeLimit = Config.LiveCrime.caseTime` (1800, 60–3600), one location at the
  crime with `sceneRadius` as start circle. `LC.liveOf(crime) = { crimeKey, dispatchId, title, street, suspects }`.
- `CP.Runs.create` with `opts.live` sets `run.live` and `run.realSuspect = 'live'` before the route lock, skips
  `capsOk`, passes `exemptFor(run)` to the on-call re-check; a `live_crime` row starts a type cooldown only with
  `typeCooldown`.
- `run:created`: `crime.runId`; `Opp.open(run, { kind = 'live', index = 1, members = crime.suspects, scene })`; armed
  suspects noted; a participant with `rs_linked_accounts` from `selfBlock` is flagged. No case possible → the run ends
  `cancelled` (no cooldown, no penalty).
- `run:ended`: `Opp.close(run)`, `Opp.recordPairs` (one row per participant and suspect; `scored` = completed with the
  suspect detained or booked at a share above 0; `gone` when no participant arrived), `Opp.checkPairFlags`. A claimed
  LIVE call closes with its run and is never re-dispatched.

#### Backup joins the case
While `enabled` and `Config.LiveCrime.backup` (shipped true) are on, an on-duty officer on no mission is asked
(`LC.offer(run, src, why)`, `client:liveJoinOffer`, an ox_lib alert closed after `joinOfferSeconds`, 30, 10–120) when
he marks himself responding to the crime's own call (an officer still on a mission is asked 3 s after CP.Calls ended
it), stands within `sceneRadius` of the place (scanned at most every 5 s per case, `maybeOfficer` first), or cuffs a
suspect from outside the case. One offer at a time per officer and case. `LC.joinCheck(run, src)`:
`err.live_join_off`, `err.live_case_gone`, `err.live_join_already`, `err.already_on_run`, `err.live_join_full`
(`maxOfficers`, 6, 1–16), then the officer rules of a claim. A yes (`server:liveJoin`, `LC.answer`, the right token in
time) → `CP.Runs.addParticipant(run, src, { via })`: refuses a run that is not live or ends, `err.live_join_left` (a
leave is final), on a run, arena, `getOfficer`, mission ban, on call (with `exemptFor`), field training's ride-along
rule, then `joinCheck` again with no yield until he is registered (`joinedLate`, `sharedBefore` = a copy of
`run.score.shared`, so shared lines from before are not his). He gets `client:start` (the kept `clientStart`), the
combat settings, the route, and while in progress `client:inProgress` and the active objective's client half; the
officers are told, `participant:joined` fires and the view and HUD are pushed. Pair rows include him.

#### The officers' tablet
`Config.LiveCrime.caseCard` and `resultOutcomes` (both true). Labels and counts only: never a citizenid, server id,
position, or one suspect's state while it runs.
- Ready check (with `readyCheck`): `extra.live = LC.readyLine(ctx.live)` (`{ title, street, suspects }`) in the check
  and `client:readyCheck`; the banner shows the red LIVE line.
- Active Mission: `Runs.view` adds `live = LC.caseView(run, src)` (`{ title, street, suspects, host, phase }` plus the
  block's `caseView(ctx)`, §7.3); the LiveCaseCard shows the three steps, the count, the last report and the next,
  and for the host where End case is.
- Result card: `rr.live = LC.resultView(run)` (`{ title, street }`, plus `open = true` for one who left while it ran, or
  `outcomes = { { label, outcome } }` once ended; `resultView` closes the case, which is idempotent).

#### Scoring
A run is live when it carries `run.live` or `run.realSuspect = 'live'`; the rules read the run, never `enabled`.
- `LC.isLive(run)`, `LC.linesOnly(run)` (`Config.LiveCrime.linesOnly`, true): `Scoring.compute` makes the subtotal the
  lines only (the live_* lines, detain and booking weighted by share, conduct penalties) without the end-of-run lines;
  P stays the base of pct shares and the cap; the breakdown carries `linesOnly = true`.
- `LC.tierRow(run)` (`Config.LiveCrime.tier`, 'crew'): the Config.Scaling row for `LC.crewSize(run)` is the points and
  cash multiplier and the pay tier; 'officers' = the run's own tier.
- `LC.counts(run, what)` for typeOfTheDay, goals, challenge, cash, items: true for other runs, for a live run only
  while that `Config.LiveCrime` switch is on (all false: no x2, B = 0, no item roll). `cash` and `items` are plain
  switches. `LC.rowFilter(what, alias)` adds `AND COALESCE(mission_id, '') <> 'live_crime'` to the goal and challenge
  sums while off. `LC.MISSION_ID = 'live_crime'`.
- Live catches: `noteStat(run, nil, 'live_catches', 1)` per suspect whose detain line was recorded;
  `cp_mission_runs.live_catches` (migration 014); the board metric `live_catches` (not shipped on the list).

#### Results for other scripts
- `LC.sendEnded(run, state, reason, outcomes, case)` from `run:ended`, once per run, not for tests, while
  `Config.LiveCrime.endEvent ~= false`: `TriggerEvent('crimson-police:server:liveCrimeEnded', { resource, uid, id, key,
  result = state, reason, suspects = { [cid] = outcome }, caught, officers, endedAt })` in pcall (no server id, no
  position).
- `LC.availablePolice() -> count, { [dept] = count } | nil` and the export `GetAvailablePolice` (nil while off): online
  players on duty in a turned-on department; with `Config.LiveCrime.availablePolice = 'idle'` (shipped; or `duty`) only
  those on no mission. Memory only, never yields. Tests `tests/live_results_spec.lua`.

#### Surrender and Talk them down (modules/opponents/surrender/server.lua)
`Config.RealSuspects.surrender` (`enabled` true; also needs `Config.LiveCrime.enabled`); live cases only. A surrender is
a mark on the record (`rec.surrender = { at, coords, by, ended }`), never a state: cuff, detain and booking stay the
proof's.
- The suspect's command (`command`, `surrender`; registered the first time the feature is on, a new name needs a
  restart; 2 per 3 s): refuses `livecrime.surrender.off`, `not_wanted`, `already`, `cannot` (down, in an instance),
  `pending`; else the question.
- Talk them down (`server:liveTalkDown`, 2 per 2 s): an active participant of an open live case, the nearest free
  suspect (online, bucket 0, not down, not surrendered) within `talkRange` (15 m), one open question per suspect, the
  same pair again after `talkCooldown` (30 s).
- The question `client:liveSurrenderAsk { token, seconds = askSeconds (20, 5–60), talk }`, answered with
  `server:liveSurrender(token, yes)` (3/s): no → `talk_refused`; yes in time, still a free suspect not down, bucket 0, an
  officer of the case within `surrenderRange` (50 m) → `rec.surrender`, `surrendered`, everyone told (labels only).
- A surrender ends when he was cuffed after it and is free again, a weapon was seen after it, he moved more than
  `breakRange` (10 m), or after `holdSeconds` (120). An officer within `talkRange` of a free suspect gets a hint once.
- `Opp.peaceful(run, cid) -> bool, by`: a surrender not ended, cuffed after it, not detained by a leave, no officer hit
  since. Tests `tests/live_surrender_spec.lua`.

### 5.47 CP.Volunteers — modules/volunteers (server, client; stub)

Volunteer suspects (`Config.Volunteers`, `enabled` shipped false). A player not on police duty volunteers for an hour
with `Config.Volunteers.command` and only sees ox_lib notifications, dialogs and a context menu (no tablet). A mode per
mission type or mission (`'npc'`, `'players_when_available'`, `'players_only'`) decides whether a mission whose block
offers a volunteer slot (§7.3) is played against a volunteer who said yes instead of the NPC. Every mode ships `'npc'`,
so nothing changes even with `enabled = true`. The owner's checklist and the rules to paste are README 9.16; the SOP
has the same rules.

#### The opt-in (modules/volunteers)
- `check(src) -> ok, reason, info, untilAt`: `enabled`, a loaded character, `CP.Opponents.eligible(src)`, an admin's
  Exclude, and the strike block of his player key (the license, else `cid:<citizenid>`, so other characters are blocked
  too).
- `join(src, roles)` (roles `{ runner|driver|fugitive = true }`, at least one) lists him for `windowMinutes` (60) and
  starts his AFK samples; `renew(src)`, `setRoles(src, roles)`, `stop(src)`, `list()` (oldest first), `isListed(cid)`,
  `strikes(cid)`, `endListing(cid, why)`. Ends (told as `volunteer.ended.<why>`, except `left`): stopped, expired,
  on_duty, excluded, strikes, disabled, left. A 15 s sweep runs only while the list holds someone. The list is memory
  only (after a restart a player volunteers again).
- `strike(cid, why) -> count, blockedUntil|nil`: a yes followed by a no-show or walking away; `strikes` (3) within
  `strikeHours` (24) block for `blockHours` (24). With `Config.Volunteers.saveStrikes` (shipped true) strikes and
  blocks are `cp_pvp_pairs` rows of kind `vol_strike` / `vol_block`, read at start and pruned at start and daily.
  `clearStrikes(cid)` (the staff tool, §5.45).
- Net: `server:volunteer` (action, data; 4 per 2 s): `open` → `client:volunteerMenu` (`{ active, minutes|minutesLeft,
  roles, strikes, maxStrikes, case? }`), `join`, `renew`, `roles`, `stop`, `answer`, `cancel`; every answer is
  `client:volunteerNote` (kind, key, vars), refusals `volunteer.refused.<reason>`.
- Client: the command is registered once `enabled` is on (restart to rename; later off answers
  `volunteer.refused.off`). Start: an ox_lib alert with the rules, then one checkbox per role; listed: a context menu
  (time left, Renew, Change roles, Stop with a confirm). Tests `tests/volunteers_spec.lua`,
  `tests/volunteers_client_spec.lua`.

#### Modes, slots and who is free
- `modes` (per type, shipped `'npc'` for each) and `missionModes` (per mission, beats its type, `{}`), Settings
  `Volunteers.modes` / `missionModes` (a `modes` key must be a type, `err.setting_volunteer_type`).
- `modeOf(def)` (`'npc'` while off, for the boss and for no mode), `slotOf(def, index)` (the first objective whose
  block's `volunteerSlot(obj, def, location)` answers `{ role, ... }`; cached; an error is no slot), `slotRoles(def)`,
  `canTake(def)`.
- `available(roles)` (listed, not held, oldest first), `reserve(holder, def, index)`, `rekey(old, new)`,
  `release(holder)`, `reservedFor(holder)`. A hold ends with `run:ended`, the volunteer's listing, or resource stop; a
  held volunteer is never offered to anyone else.
- `drawGate(def, realOk)`: only `'players_only'` closes a mission (`real_suspect`, `no_slot`, `no_volunteer`);
  `cardInfo(list) -> nil | { required, available }`.
- CP.Draw: `pool(type, members, { realSuspect })` drops missions `drawGate` closes (board reasons
  `board.locked_real_suspect` / `board.locked_no_volunteer`; draw `err.real_suspect_needed` / `err.volunteer_none`); a
  `'players_only'` mission is drawn only at a location with a slot. The card carries `realSuspect = cardInfo(list)`;
  `server:acceptType` takes `payload.realSuspect == true`. Claims and pushed missions carry no tick (`'players_only'`
  left out; `Draw.checkMission` refuses one, `err.mc_push_volunteer`). After the draw, with the tick and a non-npc mode
  at a slot location, `CP.Runs.create` gets `volunteer = { mode, role, obj }` (never a citizenid; not for live, boss or
  test runs); `'players_only'` also holds a volunteer (none: `err.volunteer_none`).
- Mission Board: a red "Real suspect" badge; its accept dialog (always opened) has a "Real suspect OK" toggle (off),
  with "required" and the free count.
- Config health `volunteers`: warns for unknown keys, non-modes, and a non-npc mode with no slot (`no_slot` plays the
  NPC, `no_slot_only` never offered). Tests `tests/volunteer_modes_spec.lua`.

#### Matching, consent, travel and engagement (modules/volunteers/match/server.lua)
Memory only; only for runs with `run.volunteer`.
- Start: `run:created` one frame later → `V.match(run)` (the slot's role, `meet` (else the start), `meetRadius`). One
  2 s thread while a match asks or has a volunteer.
- Asking: the held volunteer first, then `available({ [role] = true })`, each once, at most `askTries` (3). A candidate
  must pass `V.check`, `eligible(src, { intake = true })`, `Opp.selfBlock` for every participant and `V.capsOk(run, cid)`
  (`suspect_used`, `officer_suspended`, `officer_recent_suspect`, `pair_blocked`, `pair_cooldown`). He gets
  `client:volunteerAsk (token, { role, seconds = askSeconds, km, travelMinutes })` (closed with
  `client:volunteerAskClose`). A no, no answer or an ended listing asks the next one — never a strike. The answer must
  be his own open token, from the asked server id, at most 2 s late (`volunteer.ask.too_late`); a yes re-runs every check
  (`volunteer.ask.not_now`).
- Yes: `Opp.open(run, { kind = 'volunteer', index = obj, members = { cid }, meet })`, `run.realSuspect = 'volunteer'`
  (CP.Calls, Alerts, Downed and Route now treat it as a real-suspect case), `CP.Alerts.releaseRun`; officers told;
  officers whose `selfBlock` flags `rs_linked_accounts` are flagged (also later joiners). The volunteer gets
  `client:volunteerCase { phase = 'travel', role, meet, seconds = travelSeconds, radius }` (his own waypoint); his
  listing does not expire while he plays.
- Travel: within `meetRadius` → `in_position`; late after `travelSeconds` → no-show. First contact → `engaged`:
  `CP.NpcCombat.dropFor(run, src, 'volunteer')` for every participant and later joiner unless
  `Config.RealSuspects.npcCombat`.
- Dropping out: a no-show, his own Cancel this case (also Stop volunteering while playing), his suspect `left`/`void`,
  an AFK catch with `afkCatchVoids` (true), or `V.outOfBounds(run)`: the suspect goes `void`, a staff note
  `rs_volunteer_dropout` (a leave already has `rs_combat_log`). Strikes: no-show, leave, AFK, out of bounds, and a
  cancel later than `cancelGraceSeconds` (60) after the yes or the engagement.
- Endings: nobody said yes → `'players_when_available'` plays the NPC, `'players_only'` ends. A dropout before the
  engagement → the NPC while `onVoid = 'npc'` (shipped) and not `'players_only'`, else the end; after the engagement
  always the end: `voidRun = 'cancelled'` (shipped; `cancelRun`, no cooldown, penalty or pay) or `'keep_earned'`
  (`endRun` completed with `run.keepEarned`: lines only, no mission cash).
- Release (`run:ended`): an open question closes, the player gets `phase = 'over'`, the hold goes; `Opp.close`, one
  pair row per participant (kind `volunteer`; `gone` while no officer reached him), `Opp.checkPairFlags`.
- Blocks read `ctx.volunteer()` (`V.matchView`: `{ role, mode, phase = asking|travel|in_position|engaged|npc|void, meet,
  label, real, engaged }`, never an id or a live position) and may tell the volunteer `V.caseNote(run, kind, key,
  vars)` and `V.caseArea(run, area|nil)` (`client:volunteerArea`) in travel, in_position or engaged.
- Keys: `askSeconds` (30, 10–120), `askTries` (3, 1–10), `travelSeconds` (300, 60–1800), `meetRadius` (25, 5–200),
  `cancelGraceSeconds` (60, 0–600), `onVoid`, `voidRun`, `afkCatchVoids`, `doorAssociates` (false), `driverNpcCars`
  (false), `driverReportEvery` (30, 0–300), `fugitiveNpcs` (false), `fugitiveOutSeconds` (30, 0–300) (§7.3). Tests
  `tests/volunteer_match_spec.lua`.

#### Scoring, results and staff
- `V.isCase(run)` (`run.realSuspect == 'volunteer'`), `V.counts(run, what)` for typeOfTheDay, goals, challenge, cash
  (`payCash`), items (`payRewards`), all shipped false: cash B = 0, no items, no Type of the Day. The breakdown carries
  `realSuspect = 'volunteer'`; `V.rowFilter(what, alias)` keeps those rows out of goal and challenge sums while off.
  `V.payVolunteer(m, run, state, reason)` asks CP.FeatureRewards (§5.52) to pay the volunteer for a fair case.
- `V.sendEnded(m, run, state, reason)`, once per run with a yes, never for tests, while `Config.Volunteers.endEvent ~=
  false`: `TriggerEvent('crimson-police:server:volunteerEnded', { citizenid, missionId, missionType, role, mode,
  outcome, dropout, engaged, result = state, reason, officers, endedAt })` in pcall (no server id, no position).
- Staff: the case keeps `case.volunteer = { role, mode, phase, why, engaged }`; `V.staffView(runId, case)` is added to
  `Opp.staffCases` / `staffCase`; `V.staffList()` (listed volunteers with roles, strikes and `playing`, no server id)
  is `admin:getRsCases.listed`. The Real suspects screen filters live/volunteer, shows the volunteer's part in the
  drawer, and has a Volunteers tab. Tests `tests/opponents_staff_spec.lua`, `tests/realsuspects_config_spec.lua`.
- End-to-end specs (files mode): `tests/realsuspects_e2e_spec.lua` (both features through the real server side, and
  that the shipped config changes nothing), `tests/workflows_e2e_spec.lua`, `tests/live_fto_e2e_spec.lua` (with a
  restart in the middle), `tests/workflows_full_spec.lua`; `docs/WORKFLOWS.md` is their table.

### 5.48 CP.Options — modules/options (S; officer options)

Each character's own tablet choices (My options), saved sparse in `cp_officers.options` (JSON of only the keys that
differ from the default; NULL = defaults; migration 010). The rules are CP.OptionDefs (§2, shared/options.lua); each
feature registers its own keys in a `shared/options_*.lua` file.
- `effective(citizenid, deptKey, raw)` — every `server` option: the default, then the saved value while the option is
  allowed and still passes `check` (a saved value of a disallowed option is ignored, not deleted).
  `Config.OfficerOptions.enabled = false`: defaults only.
- `set(src, patch)` — the officer from `getOfficer`; unknown or `local` key `err.invalid_payload`, not allowed
  `err.option_locked`, bad value `err.option_value`, a def's `guard` (`CP.OptionDefs.refused`); writes the sparse JSON,
  then push `options { values }` and hook `options:changed`.
- `view(officer) -> { enabled, schema, values }` (allowed options only; `hidden` ones left out), `config(deptKey)`,
  `decode(raw)`.
- Net: callback `getOptions`, action `server:options:set { key = value }` (both 4/s). The session carries `options` and
  `config.officerOptions`. Settings checks `Config.OfficerOptions` and each department's `officerOptions` with
  `checkConfig`.
- Admin: `admin:getOfficerLook` returns the saved `options`; `server:admin:resetOfficerOptions` (modules/profile,
  `officerRecords`, reason, audit `optionsReset`) sets them NULL; `admin:getDepartmentSetup` carries `optionDefs`,
  `optionsEnabled` and each department's `officerOptions`; `server:admin:saveDepartment` takes `fields.officerOptions`
  (`{}` = the global options) as `Departments.<key>.officerOptions`.
- Client (modules/options/client.lua): `get(key)` (not allowed → default; `local` → this PC's KVP
  `crimsonpolice:options`; `server` → the session's), `setLocal(key, value)`, `localValues()`, `refresh()`,
  `keyHint(cmd)`, `sound(group, name, set, p3)`, `activeWithin(ms)`. §8.5 lists the client actions, the NUI message and
  the hook. Web: `shared/options.ts` (`OptionsProvider`, `useOption(key)` = this PC's value, else the session's, else
  the department default).
- Screen: Officer UI `options` (`officer/screens/MyOptions.tsx`, hidden while disabled): the Tablet look and privacy
  card, one card per group (a `server` row saves 500 ms after the last change, a `local` row through `setLocalOption`;
  Back to default per group) and My keys (`getKeyLabels`). Mock `mocks/options.mock.ts` (`?options=locked`).

| Option | Store | Default | Effect |
|---|---|---|---|
| `hudSide` | local | right | the HUD column on the left (`is-left`); toasts stay top-right |
| `hudScale` | local | 1.0 (bounds 0.8–1.3) | × the HUD column scale, still fitted to the screen |
| `hudCompact` | local | false | only the current objective, with done/total and the timer |
| `reduceMotion` | local | false | body class `cp-reduce-motion` drops slide-ins and the off-route flash |
| `hudLook` | server | false | the HUD uses the officer's appearance and accent (`AmbientLook`) |
| `textSize` | server | normal | `large` = `--cp-fs-scale` 1.15 on the tablet and HUD; the `theme` message carries `prefs` and these two options, re-sent on `options:changed`, so the HUD has them before the first open |
| `toastTime` | local | normal | short 3/5 s, normal 5/7 s, long 8/12 s for info+success / warning+error (`TOAST_MS` in toast.ts and tablet/client.lua); explicit durations kept |
| `resultTime` | local | 25 (bounds 8–60) | the result card's time |
| `quietRun` | local | false | on a run, social toasts (`opts.channel = 'social'`: unit invites, profile, rewards) go to the bell only |
| `keyHints` | local | true | key labels in toasts and banners (`useKeyHint`, client action `getKeyHints`) |
| `soundCalls` / `soundUnit` / `soundCues` | local | true | `CP.Options.sound` plays frontend sounds per group (calls, unit invites and checks, block cues) |
| `favouriteTypes` / `hiddenTypes` | server | `{}` | Mission Board order (`arrangeTypeCards` in `boardOrder.ts`): favourites first, hidden folded (never all: `err.option_hide_all`); boss and operation cards never moved |
| `skipAcceptConfirm` | server | false | Accept sends at once (a Twists button opens the dialog; the dialog's lines become a footnote); the boss still asks |
| `usualTwists` | server | `{}` | the twists the accept and claim dialogs start ticked (`twistTicks.ts`), else the department's ticked ones |
| `skipClaimConfirm` | server | false | Dispatch claims at once (`mc.oneclick.note`) |
| `callAlerts` | server | all | `favourites` = call toasts only for favourite types (cached with the mute flag; a paged call still reaches the paged unit) |
| `dispatchKeyAfterCall` | server | false | the tablet key opens on Dispatch within 20 s of a call cue |
| `openOn` | server | last | `home` or `active_on_run` (the session's `opening`, `openOn.ts`) |
| `rememberFilters` / `filters` | local | false / hidden | Dispatch and Leaderboard filters kept (`filters.ts`) |
| `abandonConfirm` | server | true | false = press twice within 3 s instead of the dialog (`abandonPress.ts`) |
| `skipRecalcConfirm` | server | false | Recalculate at once |
| `distanceUnits` | local | metric | `formatDistance(m, units)` on the HUD, run bar, Active Mission, Contact panel, Dispatch (the Builder stays metric) |
| `objectiveGps`, `hudTargetLine`, `colourblindMap` | server / local / local | route / true / false | §5.44 |
| `autoReady` | server | false (locked: `allow.autoReady = false`) | answers a ready check near the leader: `server:unitReady { accepted, auto }` counted only when allowed, on, input within 60 s and within `Config.OfficerOptions.autoReadyRange` (10–1000) of the leader on the server; never for a cross-department check; else `err.unit_ready_auto` |

Every option ships allowed (except `autoReady`) with defaults that keep the tablet as it was. Walks:
`boardOrder.walk.ts`, `usualTwists.walk.ts`, `openOn.walk.ts`, `abandonPress.walk.ts`.

### 5.49 CP.DeptControls — modules/deptcontrols (S; Mission controls)

Rules a department's supervisors may change for their own department (Supervisor UI → Mission controls), only while
an admin switched them on and only inside the admin's bounds. One row of `cp_dept_controls` per department and control
(migration 011; `'*'` = server-wide); no row, an expired row (`expires_at` passed) or a switched-off control = the
config value. Each feature registers its own controls and reads them with `get` (through `Call('DeptControls', ...)`,
so a missing module reads as config).

#### API
- `register(key, { kind = 'number'|'bool'|'map'|'choice'|'action', scope = 'between'|'run', configValue(officer),
  check?, clamp?, relaxes?(value, configValue), integer?, serverWide?, master?, range = { lo, hi }, flags?, list?,
  choices?, bounded?, duration?, allow?, overlays?, carry?, viewExtra?, usedToday? })`, `unregister`, `def`, `keys`.
  `serverWide` = one value under `'*'`, changed by a supervisor of any department; `master = false` = the master switch
  does not apply. `duration(value)` saves `expires_at = now + duration` (survives a restart); `allow` adds a rule;
  `overlays` changes other controls while the row is live; `carry(ctx)` stores extra fields at a set.
- `bounds(dept, key)` = `Config.MissionControls.controls[key]` with `Config.Departments[dept].missionControls[key]` over
  it, field by field (`{ on, min, max, ... }`; `{}` = off).
- `get(dept, key, officer) -> value, row?` — the row while the master switch (`Config.Permissions.supervisor.
  missionControls`) and the control's `on` are true and it has not expired, clamped into today's bounds; else
  `configValue(officer)`. Self rule: with `Config.MissionControls.selfExempt`, when `officer` (an officer, a list or `{
  members }`) is the row's `set_by` or another character of his license and the value relaxes the rule, the config
  value. `heldBy(officer, row)`, `active(dept, key)`, `expired(dept, key)` (a 15 s tick fires `deptControls:changed {
  expired = true }`), `snapshot(leader) -> values, changed` (the scope `run` controls, stored as `run.controls` /
  `run.controlsChanged` before the deadlines are set; test runs keep the config).
- `canChange(src, key, dept) -> ok, errKey, role, dept` — admins any department (`err.control_off` while off); a
  supervisor his own (`err.other_department`), with `can(src, 'missionControls')` unless `master = false`, his grade grant
  in `Config.MissionControls.grants`, and the control on.
- `set(src, key, value, reason, opts?)` — the only write: `canChange`, a reason, the value inside the bounds
  (`err.control_value`, never clamped), for a supervisor `Config.MissionControls.changeWait` (`err.control_wait`), then
  upsert, audit `missionControlSet` (target `dept:key`), hook `deptControls:changed { dept, key }`, push
  `missionControls` to that department's supervisors (all for `'*'`) and admins. `reset(src, dept, key, reason)`
  (`err.control_not_set`; audit `missionControlReset`).
- `view(src)` (each control `{ key, kind, scope, serverWide, master, on, active, min, max, value, configValue, saved,
  setBy, setRole, at, expiresAt, timeLeft, waitLeft, flags, list, offered, choices, ... }`), `available(src)` (sent as
  `session.config.missionControls`), `mine(src)` (Your controls today, `Config.Tablet.supervisorControlsCard`, false;
  callback `sup:getMyControls`, `err.controls_card_off`), `checkConfig(map, boot)` (registered names only, `on`
  boolean, `min ≤ max` inside `range`, known flags and list names; `err.control_config`).
- Kind `action`: a staff action with no saved value (`get` nil, `set`/`reset` refuse `err.control_unknown`); `bounded =
  false` = no min/max. Kind `choice`: one name from the bounds' `list` (or every name `choices` gives).
- Rows are cached per department, cleared on every write and on `settings:changed` of `MissionControls.*`,
  `Permissions.supervisor.missionControls` and `Departments.*`; bounds are read live.

#### The controls (shipped off unless said; per department under the master switch unless said)

| Key | Kind, scope | Module | What it does |
|---|---|---|---|
| `cooldownScale` | map type → × (0–4), between; server-wide, no master, on | runs | × the mission cooldown; the cache keeps `{ at, secs, type }` and works the end out when read (`Runs.cooldowns(cid, { officer })`); `Runs.cooldownScale(type)` |
| `abandonCooldown` | number 0–86400 s; server-wide, no master, on | runs | replaces `Config.Limits.abandonCooldown` |
| `noRepeat` | bool; server-wide, no master, on | draw | false = every member's no-repeat history is empty |
| `hourlyCap` / `dailyCap` | whole 1–1000 / 0–1000 (0 = none); server-wide, no master, on | draw | `Draw.limits(officers) -> { noRepeat, hour, day }` feeds the accept checks, board and boss locks, livectl counts, Home `missionsToday` |
| `happyHour` | map `{ minutes, noRepeat }`; server-wide, no master, on (5–30 min) | happyhour | while live: `cooldownScale` reads 0 and, when ticked, `noRepeat` false (the setter's unit keeps theirs); one at a time (`err.happy_hour_running`), `happyHourPerDay` (`err.happy_hour_used`); `HH.state(officer)` in the session, `getMissionTypes`, `admin:getLiveRuns`; push `happyHour`; End now = reset `'*' happyHour` |
| `clearCooldown` | action; server-wide, no master, on | livectl | `server:sup:clearCooldowns { citizenid, scope, key, reason }` (`LiveCtl.clearCooldowns`; `clearCooldownPerDay`, `err.sup_clear_used`; never self); `sup:getOfficerCooldowns` |
| `addRunTime` | action 1–10 min (1–5) | livectl | `server:sup:addRunTime { runId, minutes, reason }` (a run with his department, never a test or his own; `Runs.addTime` with min(`addRunTimeMax`, `runTimeAddMax`) shared with admins; `addRunTimePerDay`, `err.sup_time_used`) |
| `startTimeout` | number 60–3600 s, run | runs | replaces the mission's |
| `readyCheck` | number 5–120 s, run (0 only with flag `canTurnOff`) | runs | `Runs.readySeconds(leader, officers)` → `Units.readyCheck(.., { timeout })` |
| `timeLimit` | × 0.5–2, run | runs | scales `run.timeLimit`; `run.fastBaseLimit` keeps the unscaled one for `fast_finish` |
| `idleCheck` | number 30–1800 s, run (stricter only) | anticheat | min(it, `Config.AntiCheat.idleCheck`) |
| `difficulty` | choice of presets, run (easier relaxes) | scaling | `Scaling.feel(run)`, `combat(.., run)`; NpcCombat still caps; never points or cash |
| `unitSize` | number 2..maxUnitSize (never relaxes) | units | `Units.maxSize(dept)` caps invites and joins; accept `err.unit_too_large` |
| `types` | map `{ [type] = false, missions = { [id] = false } }`, between (never relaxes) | draw | off for a member's department like `def.departments` (never the boss); accept `err.type_off_department`; card "Off for <dept> by command"; every type off refused (`err.control_types_all_off`) |
| `featuredType` | choice of every type | draw | the card's `featured` ("Recommended by command") for that department; never points |
| `missionBan` | action 1–168 h (1–24) | missionban | `cp_officers.mission_ban` (migration 012) `{ until, by, name, dept, reason, at }`, all kept in memory; `server:sup:missionBan { citizenid, hours, reason }` (online, own department, a lower grade, `missionBanPerDay`; audit `missionBan`), `server:sup:liftMissionBan` (only the setter), `server:admin:liftMissionBan` (antiFarmOverride, also while off); accept, operations join and claims refuse `err.mission_banned` / `err.member_mission_banned`; a live run is never ended |
| `callLane` | map `{ spawnEvery = { lo, hi }, maxOpen, areas, types = { [type] = 0–10 } }` 30–3600 s (120–600) | missioncalls | one call per due lane for idle units all of that department (`cp_mission_calls.department`, migration 013); counts against `maxOpen`; `err.mc_other_department`, `err.mc_own_call` (the setter) |
| `staffCallWait` | number 0–3600 s (60–120) | missioncalls | `MC.staffWait`; a shorter wait relaxes |
| `notices` | action, unbounded | deptnotices | `server:sup:postNotice { text, days, reason? }` (own department, `noticeMaxLength`, 1–30 days, one a minute, `noticesPerDay`, `NOTICES_ACTIVE`; a `cp_staff_notices` row with `by_actor = 'sup:<cid>'` shown on that department's Home), `server:sup:endNotice { id }`, `sup:getDeptNotices` |
| `crossDept` | map `{ join, places }` (never relaxes) | operations | `err.op_department_out`, `err.op_department_full`; lock and cooldown stay server-wide |
| `boards` | map `{ showToOthers, metrics }` (never relaxes) | leaderboard | `LB.boardMetrics(dept)` (the Rank by tabs; another tab `err.invalid_metric`), `LB.hidesNamesFrom(dept, viewerDept)` (callsigns only); cached boards and admin views unchanged |
| `reviewRules` | map `{ secondVoid, adminOnlyKinds }` (never relaxes) | reviewrules | `RR.voidStep`: a first supervisor Void is pending (`voidPending`), a second supervisor of the row's department voids (`err.void_second_needed`, `err.void_second_dept`); `RR.adminOnly(dept, kind)` hides such rows from supervisors (`err.review_admin_only`) |
| `twists` | map `{ offered, ticked }`, run (never relaxes) | events | `Events.deptTwists(dept)`; offers only those, marks ticked; `err.twist_department` |
| `happyHourCash` / `twistCash` | number / map `{ [twist] = × }` 1–3, run (raise relaxes) | happyhour / events | `run.controls.cashBonus` while a happy hour holds the unit not; `CP.Twists.bonus(list, scale)` before `twistMaxCash`; `Cash.compute` pays `round(B × mTier × mMod × mBonus)`; never test, operation or boss runs |
| `happyHourPoints` / `twistPoints` | the same shape | happyhour / events | `Scoring.bonusOf(run)` after the cap and ToD; `CP.Twists.bonus(list, scale, pscale)` before `twistMaxPoints` |
| `typeOfTheDay` | choice of every type (relaxes) | events | one change a day (`err.tod_picked_today`), counts from the next day (`Events.deptTypeOfTheDay(dept)` reads yesterday's last audit row); `Events.typeOfTheDay(dayKey, department, who)` unless `heldBy` |
| `goals` | map `{ daily = { id }, weekly = { id } }` 1–20 (1–5; relaxes) | goals | the department's goals from the next weekly reset (`carry` saves `from` and `prev`); `Goals.forOfficer(cid, department)` |
| `pushMission` | action | missioncalls | `MC.page(.., { missionId })`: own department, every member of it, `pushMissionPerDay` (`err.mc_push_used`), `Draw.checkMission` (enabled, not the boss, of the type, eligible, a location in the area); only the paged unit sees and may claim it; `FinishAccept` uses that mission; a decline (`server:declineMissionCall`) or failed accept withdraws it; never re-dispatched; audited `mcPush` |
| `awardPoints` | action 1–10000 (1–50) | supawards | `server:sup:awardPoints { citizenid, points, reason, confirm? }`: own department, `awardPointsPerDay` (`err.award_daily_limit`), `AdminControl.pointAdjust` (`err.award_off`), the confirm above `adjustConfirmAbove`; through `CP.Corrections.adjust` like the admin path |

#### Screens and net
- Net §8.3: `sup:getMissionControls`, `server:sup:setMissionControl`, `server:sup:resetMissionControl` (through
  `Kit.supAction`), `admin:getMissionControls`, `server:admin:setMissionControl`, `server:admin:resetMissionControl`.
- Supervisor UI → Mission controls (`supervisor/screens/MissionControls.tsx`, `sup_controls`): live on push
  `missionControls`, grouped (Delays and repeats, In a run, Board, Calls, Officers, Department), saved with a reason;
  shown while `available(src)` (with the master switch off when a server-wide control is on, as shipped).
- Admin UI → Permissions → Mission controls (`admin/components/MissionControlsCard.tsx`): the view adds `bounds`,
  each control's `own`, `integer`, `range` and each department's `boundsPath` (`Departments.<key>.missionControls`);
  saves through `server:admin:setSetting` (`MissionControls.controls`, `MissionControls.grants`, a department's
  bounds) and resets through `server:admin:resetMissionControl`; `admin:getPermissions` adds `missionGrants`.
- The supervisor views that carry each tool's limits: `sup:getOfficerActivity` (`cooldownClear`, `missionBan`,
  `missionBanState`, `awardPoints`), `sup:getLiveRuns` (`addTime`, per run `timeAdded`, `own`), `sup:getDeptReport`
  rows (`missionBan`), `MC.supView` (`lanes`, `push`).

### 5.50 CP.FieldTraining — modules/fieldtraining (S; field training)
Config.FieldTraining (ships `enabled = false`: the hook counts nothing, every action answers `err.fto_off`, both reads
answer `false`). The record is the rookie's `cp_officers.field_training` JSON (migration 015): `{ trainer, trainerName,
dept, by, byName, at, tasks = { [missionType] = { runs, signedBy, signedName, signedAt, note } }, doneAt }`; NULL = not
in training. Every read-change-write of one record runs under a per-rookie lock (`WithLock`, 50 ms waits).
- `FT.enabled()`, `FT.tasks() -> { { type, need, label } }` (Config tasks with a count above 0, sorted),
  `FT.trainerGrade(dept)` (trainerGrades, else the department's supervisorGrade), `FT.badge()` (a safe badge id),
  `FT.view(cid, name, record) -> FtoView` (web/src/types/fieldTraining.ts).
- `FT.onRowSettled(run, p, rowId, row)` on the `row:settled` hook: a completed, unflagged, non-test row of a rookie
  in active training counts one run towards the task of `run.missionType` (never above its count) when his trainer is
  a participant of the same run with `result = 'completed'`; the trainer is toasted when the count is reached.
- `server:sup:ftoPair { rookie, trainer }` and `server:sup:ftoUnpair { rookie }` (`Kit.supAction`, key
  fieldTraining (every supervisor's, grantable), `opts.permission`: the feature on and `CP.Permissions.can(src,
  'fieldTraining', { department = the rookie's department })`; S on the rookie, non-strict). Pair: trainer online (`CP.Access.getOfficer`), same
  department, grade at or above `FT.trainerGrade`, the rookie not in training, the trainer not in training himself and
  under `rookiesPerTrainer`; audited `ftoPair` (target the rookie, new the trainer), both toasted. Unpair clears the
  record; audited `ftoUnpair`.
- `server:fto:signOff { rookie, task, note? }` (CP.Net.action, rate 2): only the rookie's trainer, a task of the
  config whose count is reached and not signed yet; the note through `Kit.reason(v, true)`; audited `ftoSignOff`
  (role supervisor: cp_audit has no officer role); the last task sets `doneAt` and inserts the badge into `cp_badges`
  (`INSERT IGNORE`), both toasted.
- `FT.unitCheck(officers, missionType) -> true | false, 'err.fto_trainer_needed', rookieCid` (the ride-along
  rule, `FT.requiredTypes()` from `requireTrainerFor`, a list or a `{ type = true }` map; reads nothing while it is
  empty). CP.Draw's `CheckAccept` (board accept and mission call claim) asks it after the per-officer checks and turns
  a rookie other than the leader into `err.member_fto_trainer_needed`. `FT.trainerBonus()` (0 to 1000): after a
  sign-off, `CP.Scoring._insertBonusRow(trainer, 'manual_award', 'fto_bonus', n, ...)` (breakdown.by
  `field_training`, so supervisors' daily award limits never count it), toast `fto.toast.bonus`.
- `FT.joinCheck(cid, unitCids, missionType) -> true | false, 'err.fto_trainer_needed'`: the same rule for an
  officer who joins a live case late; `CP.Runs.addParticipant` asks it (among its yielding lookups) with the active
  participants' citizenids as his unit and `run.missionType`. While enabled, `Scoring.badgeCatalog()` lists
  `FT.badge()` among the achievements (label `badge.field_training`, need 0) and `Scoring.validBadgeId` accepts it,
  so the Admin UI grants and revokes it like an achievement (its override never re-runs a count).
- Reads: `fto:getMine` (Profile → Field training: `{ training?, rookies, trainerBonus }`, `training.needsTrainer` the
  ride-along type labels; `false` when off or nothing to show) and
  `sup:getFieldTraining { department? }` (Department Report: `FtoDept`, the department's pairings, up to 300 officers
  as rookie candidates and the online trainers; a supervisor only his own department, admins any).
- Web: web/src/officer/components/FieldTrainingCard.tsx (FtoTaskList, FtoProgress, the Profile card with Sign off) and
  web/src/supervisor/components/FieldTrainingPanel.tsx (Department Report: Pair trainer, End training on two clicks).
- Tests: tests/field_training_spec.lua (plain Lua, stubbed rows); the 015 column and its JSON_VALUE read in
  tests/foundation_spec.lua.

### 5.51 CP.CrimTab — modules/crimtab (client, server; the criminal tablet)

A front end of CP.Volunteers (5.47) for players who play real suspects, behind `Config.CriminalTablet` (shipped off).

- Server: `CP.CrimTab.canUse(src)` -> ok, errKey, info (`err.crimtab_off`, `_not_loaded`, `_on_duty` (police on duty,
  always), `_police` (access `'everyone'`: a police job of Config.Departments), `_no_access` (access `'granted'`: no
  `criminalTablet` extra grant, CP.Permissions.granted)); `view(src)`; `replacesCommand(src)`; `record(payload)` /
  `historyOf(cid)` (memory, newest first, `historySize`). Callback `crimtab:get` -> the view; action
  `server:crimtab:act` `{ what = 'join' | 'renew' | 'roles' | 'stop' | 'answer' | 'cancel', roles, token, yes }` ->
  the fresh view or a `volunteer.refused.*` / `err.crimtab_*` key. History lines come from `CP.Volunteers.recordHistory`
  at the run's end (also with `Config.Volunteers.endEvent = false`). `client:crimtabOpen` (the volunteer command with `replaceCommand`) and
  `client:crimtabClose` (duty or job change that ends access).
- CP.Volunteers adds `strikeInfo(cid)`, `listingOf(src)`, `refusalKey(why)`, `askOf(cid)` (token, role,
  missionType, area = the location label, km, seconds, travelMinutes) and `caseOf(cid)` (phase, role, his own meet
  point, seconds, freeCancel, graceSeconds). Never a run id, an officer, a server id or a live position.
- `criminalTablet` is a grantable extra power (5.3) that `actionsFor` never lists (no Supervisor UI).
- Client: `/crimtab` (`command`) and the `useCriminalTablet` export (`item`) open it with
  `CP.Tablet.panelFocus('crimtab')`; NUI message `crimtab` `{ open, view, screen }`; NUI endpoints `crimtabClose` and
  `crimtabAnswered` (closes the pop-up of that token). It refreshes on the volunteer client events only while open.
  While it is open a question goes to its Jobs screen instead of the pop-up; closing it shows the pop-up for the
  seconds left (`CP.Volunteers.tabletClosed`).
- NUI: web/src/criminal (CriminalTablet.tsx, model.ts, criminal.walk.ts), its own CSS; mocks/criminal.mock.ts
  (`?ui=crimtab`). Spec: tests/crimtab_spec.lua.

### 5.52 CP.FeatureRewards — modules/featurerewards (S; feature rewards)

Money and items for the features outside a mission's own pay, behind `Config.FeatureRewards.<feature>.enabled` (all
shipped false, each with a default money amount): `suspect` (the volunteer, by outcome), `surrender` (the officer who
talked a live-case suspect down), `ftoSignOff` (the trainer per task), `ftoComplete` (the rookie), `supAward` (per
point awarded, up to `maxMoney`).

- `FR.pay(feature, cid, { key, outcome, points, reason })` (must yield) -> `{ rowId, status, amount, items }` | nil,
  why (`off`, `invalid`, `nothing`, `duplicate`, `busy`, `error`). One cp_mission_runs row: mission_type
  `manual_award` (out of every run count), mission_id `reward_<feature>`, run_uuid `FR.uuidOf(feature, key, cid)`
  (`fr-<code>-<hash>`, at most 36 characters; the same key never pays twice), department `none` for a suspect, the
  breakdown's `cash.account` / `cash.moneyItem` / `cash.source = 'server'` (suspect). Audited (`featureReward`),
  paid by `CP.Cash.pay` (pending while offline, the daily cap), items rolled by `FR.rollItems` (deterministic per key
  and player, `CP.Rewards.usable`) and stored as run rewards of that row through `CP.Rewards._grant` (so
  `Config.Rewards.enabled` and its daily caps apply, and voiding the row forfeits them).
- `FR.payLater` runs it in a thread for the hooks: `V.payVolunteer` (5.47; `FR.fairSuspect`: engaged, no dropout,
  not AFK, outcome got_away / detained / booked; key = the run id), the live_response block's peaceful arrest (7.3;
  the talking officer's citizenid from `run.participants[by]`; key `<runId>:<suspect cid>`), `FT.signOff` (key
  `fto:<rookie>:<task>`, and `fto:<rookie>:done` when the training is done) and the `server:sup:awardPoints` action
  (key `sup:<award row id>`).
- CP.Cash's PayClaimed honours the row's `cash.account` (`bank` | `cash` | `item`: `FR.giveMoneyItem`, CanCarryItem
  then AddItem, a raise leaves the row paying) and `cash.source = 'server'` (never the society account).
- Settings: the `FeatureRewards.*` paths (economy features `reward_*`, each with its money, account, items and
  `Rewards.enabled` as limits); `FR.checkSetting` (registered validator) refuses forbidden items, items ox_inventory
  does not know (`CP.Rewards.itemKnown`), counts outside 1-100 and chances outside 0-1.
- `suspect.byType` (`{ [mission type] = { got_away, caught } }`, shipped `{}`): `FR.money('suspect', {
  outcome, missionType })` pays the type's amount for that outcome when set, else `money.got_away` / `money.caught`;
  `FR.suspectEnded` passes the end payload's `missionType`, and `CP.CrimTab.rewardText(missionType)` shows the job's
  own amounts. `FR.checkSetting` refuses an unknown type, another outcome key or an amount outside 0-1,000,000
  (`err.feature_reward_by_type`). The Admin UI Rewards screen (`Config.AdminUi.rewardsScreen`, session
  `config.adminUi.rewardsScreen`; web admin/screens/Rewards.tsx, admin/components/rewardsScreen.ts) edits these paths
  and the mission types' payouts and pools through `server:admin:setSetting`. Spec:
  tests/feature_rewards_spec.lua (and the hook lines in field_training, sup_award_points, live_response and
  volunteer_match specs).

### 5.53 CP.MissionBlips — modules/missionblips (client, server; extra mission blips)

The other parts of a mission on the minimap and the big map, behind `Config.MissionBlips.enabled` (shipped false; every
part's `on` shipped false too).

- Server: `MB.pass()` runs every `refreshEvery` seconds (`CP.Perf.armed`, armed by `run:created`,
  `participant:joined` and `settings:changed`; it stops when the switch is off, or no run is going and no map has
  blips). `MB.collect(run)` lists the parts that are on: run entities by role (`ROLE_PART`; the service vans by tag;
  any other object is `sceneProp`), the vans' parking points (`CP.Custody._servicesOf`, status coming / parked /
  loading), Manhunt hiding spots whose fugitive ran (`ctx.state.fugitives[*].ran`), a live case's scene and
  `ctx.state.reported`, the nearest `Config.Downed.dropOffs` point while a case suspect is `down`, and the run's
  officers. Never listed: a dead entity, a hidden contact (`hiddenCfg`), an entity of a pending (staged) objective, a
  real player suspect. `MB.viewFor(run, src, items)` keeps what one officer may see: not himself, a partner only in
  his routing bucket, `MB.allowed(part, run, src)` (`rules[part]`: departments, jobs, grade, missionTypes, missions,
  roles `all | leader | supervisor`, all AND-ed; officers read through `CP.Access.getOfficer`, kept 15 s), and Radio
  Silence (`'area'` drops moving people and cars but the vans, `'none'` keeps only the vans and their drop-offs).
  The prisoner van and tow truck are parts only while `Config.Markers.serviceVehicles` is off (§5.44 shows them).
  Positions are rounded (1 m points, 25 m moving), and a list is sent only when it changed.
- `client:missionBlips` `{ runId, items = { { k, p, n?, s?, x, y, z } } }` (an empty list clears); sent to each
  officer when his list changes, empty at `run:ended`, `participant:left` and when the switch goes off.
- Client: `MB.apply(runId, items)` adds, moves, restyles or removes only what changed (look read live from the
  config), `AddBlipForEntity` once the netId or partner's ped streams in (1 s follow check, `CP.Perf.ms`, only while
  such a blip is on the map), `SetBlipDisplay(2)`; `MB.clear()` at the run's clean-up (modules/runs), logout
  (`CP.Qbx.onUnload`) and resource stop. Settings: `MissionBlips.*` ranges, the `MissionBlips.rules` template, the
  Features row `mission_blips`. Specs: tests/missionblips_server_spec.lua, tests/missionblips_client_spec.lua.
- Admin UI: the Mission blips screen (`admin_blips`, NPC missions; `Config.AdminUi.missionBlipsScreen`, session
  `config.adminUi.missionBlipsScreen`, shown unless false; web admin/screens/MissionBlips.tsx,
  admin/components/missionBlips.ts) reads `admin:getSettings` and `admin:getMissions` and saves each part field and
  the whole `MissionBlips.rules` value through `server:admin:setSetting` (checked and audited as any setting). Walk:
  admin/components/missionBlips.walk.ts.

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
  relations *from* these two groups are set; `PLAYER`'s own relations are never changed (§0 rule 14).
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
More states: `contacted`, `escorted`, `seated`, `released`, `handed_over`, `impounded` (§5.11). A contact's
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
                                   -- state only: a block places its people in start or stage; the
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
fugitive) offer one, and CP.Volunteers (§5.47) uses it to find the objective a volunteer can play. The registry
(shared/init.lua): `CP.Blocks.register` drops a `volunteerSlot` that is no function (with a warning) and
`CP.Blocks.withSlot()` lists the block ids that offer one; the answer must carry a §5.47 role (runner, driver,
fugitive) or it is no slot. flee_arrest, pursuit and search_area offer one (below).

**flee_arrest's runner slot (blocks/flee_arrest).** Door mode only (Warrant Service): `volunteerSlot` answers
`{ role = 'runner', meet = <the location's suspect point> }`, none for scatter mode or a location with no suspect point.
The block reads `ctx.volunteer()` on start, every tick and on every `opp_*` event (`st.vol`):
- nil (no match, `enabled` off, a mode 'npc', or phase `npc`): nothing changes (the NPC at the door).
- `'wait'` (phase `asking`): nobody at the door; the knock is taken with no response line, the HUD says
  `block.flee_arrest.detail_waiting`; the objective cannot complete. Phase `npc` later spawns the NPC as usual (a
  knock already made applies his rolled response at once).
- `'real'` (travel, in_position, engaged): no NPC suspect; the knock shows `block.flee_arrest.response_volunteer`. The
  wanted person counts as present; he is done once CP.Opponents' view (`Opp.view(run)`, this objective's index) has
  him `detained` with a share above 0 or `booked`; a share of 0 (an AFK catch) never counts while
  `Config.Volunteers.afkCatchVoids` is on (shipped), and counts like any detain with it off; `lost` fails the objective
  `block.flee_arrest.fail_escaped` (as an NPC who escaped). The pointer stays the door point while no NPC of the
  objective is out (never his position); presence measures to the door.
- `'void'` (phase `void`: the run ends for want of him): nothing spawns.
- Associates: `Config.Volunteers.doorAssociates` false (shipped) = none while `st.vol` is set (the hostile group shoots
  every player, the volunteer too); true = they come out at the knock as usual.
- Voids go through CP.Volunteers (§5.47, `onVoid` / `voidRun`); the block never ends the run for them. An AFK catch
  (CP.Opponents set `share = 0` at the cuff) is a void there: the match's 1 s watch sees him `detained`/`booked` with
  share 0 -> `Voided(m, 'afk', strike)` (a strike, timeline `volunteer_afk`, his note `volunteer.case.afk`; the proof
  already wrote `rs_afk_catch`), counted as engaged, so the run ends as `voidRun` says. Specs:
  tests/flee_arrest_volunteer_spec.lua, tests/volunteer_match_spec.lua.

**pursuit's driver slot (blocks/pursuit).** Stop mode only, with no contact hand-off (Stolen Vehicle Takedown
hands its stopped car to field_contact, which works NPC occupants), no `observe` (Traffic Enforcement) and no `team`:
`volunteerSlot` answers `{ role = 'driver', meet = <the first car's point: spawns[1], else spawn, else the start> }`,
so of the built-in missions only Street Race Bust offers one; a custom stop pursuit may too. The volunteer drives his
own car (no car is made for him). The block reads `ctx.volunteer()` on start, every tick and on every `opp_*` event
(`st.vol`; all its code sits in one local table `Vol`, the file is near Lua's 200 locals):
- nil (no match, `enabled` off, a mode 'npc', or phase `npc`): nothing changes (the NPC cars).
- `'wait'` (phase `asking`): no car is made and the start trigger is held (a race does not start); the HUD says
  `block.pursuit.hud_volunteer_wait`; the objective cannot complete. Phase `npc` later makes the cars as usual and
  the trigger runs.
- `'real'` (travel, in_position, engaged): `VehTarget` is 0, or one fewer than the objective's cars with
  `Config.Volunteers.driverNpcCars` true (the other racers still come; the trigger runs once one exists). He is one
  more car and one more suspect on the counts, the checklist and the snapshot (`vtotal`, `total`); he is done once
  CP.Opponents' view (this objective's index) has him `detained` with a share above 0 or `booked` (the AFK rule of
  V23, `afkCatchVoids`); done is kept, adds one to `st.detained` and awards the objective's `detainBonus` once (a
  detained racer: `all_or_timeout_any` and `onTimeout` count him). `lost` fails the objective
  `block.pursuit.fail_escaped`. HUD (client half, from the snapshot's `volunteer` / `volunteerDone` only):
  `block.pursuit.hud_volunteer` while every NPC car is stopped and he is not caught, else the usual lines.
- Pointer: the NPC cars and people, plus his last-reported point (`key = 'last:driver'`, look
  `searchArea`, "Suspect vehicle: last reported"): CP.Opponents' server-side `rec.lastCoords` while he is free,
  online and outside an instance, taken every `Config.Volunteers.driverReportEvery` s (30; 0 = none) once his phase
  is `in_position` or `engaged`, never in between and dropped once he is caught; with nothing else to show, the
  first car's point (the meet point). Presence: the NPCs, else his server-side last coordinates (never
  sent), else the start.
- `'void'`: nothing spawns. Voids (no-show, cancel, leave, AFK catch) stay with CP.Volunteers' `onVoid` / `voidRun`.
  Spec: tests/pursuit_volunteer_spec.lua.

**search_area's fugitive slot (blocks/search_area).** Every search_area objective (Manhunt): `volunteerSlot`
answers `{ role = 'fugitive', meet = <the location's first hiding spot> }` (inside the start circle, so being in
position means being inside it). He hides on foot or by car anywhere in the circle. The block reads
`ctx.volunteer()` on start, every tick and on every `opp_*` event (`st.vol`; all its code sits in one local table
`Vol`):
- nil (no match, `enabled` off, a mode 'npc', or phase `npc`): nothing changes (the NPC fugitives).
- `'wait'` (phase `asking`): no fugitive is made (clues still are), the HUD says
  `block.search_area.hud_volunteer_wait`; the objective cannot complete. Phase `npc` later makes the fugitives.
- `'real'` (travel, in_position, engaged): `FugTarget` is 0, or one fewer than the objective's (scaled) fugitives
  with `Config.Volunteers.fugitiveNpcs` true. He is one more fugitive on the counts and the checklist; done once
  CP.Opponents' view (this objective's index) has him `detained` with a share above 0 or `booked` (the AFK rule of
  V23, `afkCatchVoids`); done is kept and counts one arrest. `lost` fails the objective
  `block.search_area.fail_escaped`. HUD: `block.search_area.hud_volunteer` once every NPC fugitive is caught.
- The circle shrinks towards him: at each clue, `FugitiveAnchor` is his server-side `rec.lastCoords` (free, online,
  outside an instance) once he was seen inside the circle and while he still is, else his meet point; the new centre
  lies within `CENTER_SHARE` of the new radius from it, as for an NPC. Officers get the circle, never a point of him
  (the pointer is the circle and the clues; there is no last-reported point for a fugitive).
- His own map: `CP.Volunteers.caseArea(run, { x, y, z, r })` (`client:volunteerArea`, a red radius blip on his
  game only) when he starts playing and after each shrink; `nil` once he is caught, and phase `over` removes it.
- The circle rule (out of bounds): from `in_position` / `engaged` on and once he was seen inside the current circle,
  being outside it (2D, the server's coordinates) sends one warning (`CP.Volunteers.caseNote`,
  `volunteer.case.out_warn`); back inside resets the clock; `Config.Volunteers.fugitiveOutSeconds` (30, Settings
  0-300; 0 = no rule) outside -> `CP.Volunteers.outOfBounds(run)`: `Voided(m, 'out_of_bounds')` (a strike, timeline
  `volunteer_out_of_bounds`, staff note `rs_volunteer_dropout`, his note `volunteer.case.out_of_bounds`), then the
  run goes on as `onVoid` / `voidRun` say. While travelling, cuffed or never yet inside there is no rule.
- `'void'`: no fugitive is made. Spec: tests/search_area_volunteer_spec.lua (and tests/volunteer_match_spec.lua for
  caseArea / caseNote / outOfBounds).

**The block (blocks/live_response).** `engineOnly = true` in its `CP.Blocks.register` table:
`Missions.normalize` refuses it unless `meta.engine == true` ("objective N uses engine-only block", plain reason
`missions.reason.engine_block`), and the Mission Builder answers `builder.error.unknown_block` for it (it has no
Config.Blocks entry, so builder:config never lists it). Its settings are Config.LiveCrime keys. Server half:
- Scene: `Opp.view(run).scene` (the crime's coords), else `obj.scene`, else the location's start.
- Respond: an active participant within `sceneRadius` (75 m) of the scene, or any suspect with contact -> phase
  `secure` (timeline `responded`). Secure: the 1 s tick adds dt while an officer is within `sceneRadius`; at
  `secureSeconds` (60; 0 = at once) -> phase `detain`, the shared line `live_scene` once and the timeline line
  `scene_secured`. Detain and book stays open to the end.
- HUD: `{ detail = block.live_response.hud_<phase> }` (the secure phase adds `value`/`max` seconds), sent only when
  the phase or the secure second changes. Checklist: Respond, Secure the scene (seconds), Detain and book the suspects
  (never done, never counted). Neither reads one suspect's state.
- Lines: CP.Opponents' server-only `opp_detained` -> `ctx.award('live_detain', { weight = ev.share })`, `opp_booked`
  -> `live_book`, once per suspect each, shared (every active participant); share defaults to 1, 0 (an AFK catch)
  records no line. Config.Bonuses `live_scene` (pct 0.25), `live_detain` (pct 0.50, each), `live_book` (pct 0.25,
  each) are engine-only. Other opp_* events are accepted and ignored.
- Peaceful arrest: on `opp_detained`, after the detain line, `CP.Opponents.peaceful(run, cid)` true and a share
  above 0 -> `ctx.award('peaceful_arrest', { weight = share })` once per suspect (shared) and the timeline line
  `peaceful_arrest` with `by` = the officer who talked him down (nil for his own surrender). Config.Bonuses
  `peaceful_arrest` (pct 0.15, each) is engine-only. The client half adds the radial item **Talk them down**
  (`crimson-police:live_talk_down`, every officer of the case, while `Config.LiveCrime.enabled` and
  `Config.RealSuspects.surrender.enabled`; `server:liveTalkDown`), removed at stop and onResourceStop.
- End: client evidence `{ type = 'end_case' }` from the run host completes the objective (timeline `end_case`;
  others: `not_host`); `onTimeout` answers `'completed'` (a real case ends with what was earned); the dead case: no
  suspect free, cuffed or detained (or no case) for `deadCaseSeconds` (30) -> `ctx.complete({ reason = 'dead_case' })`
  (timeline `dead_case` once). Any other client evidence is refused.
- Presence: metres outside the scene radius, or to the nearest suspect's last server position (never sent).
- Marker: while responding the scene as a point (GPS on); then `kind = 'targets'`, `route = false`: the scene and one
  coordinate target per suspect who was free, online and outside an instance at the last report (`rec.lastCoords`,
  key `last:<label>`, look `searchArea`, "Suspect A: last reported"), refreshed every `lastReportedEvery` s (60; 0 =
  none), never in between, so a suspect is never followed live.
- Case card: `caseView(ctx) -> { phase, secureS, secureNeed, reported = { label... }, reportedAgoS,
  nextReportS, reportsOn }` for the officers' Active Mission card (CP.LiveCrime.caseView); `st.reportedAt` is the
  os.time() of the last report. Labels and times only, never a position or one suspect's state.
- Client half: only "End case" in the ox_lib radial menu (`lib.addRadialItem`, id `crimson-police:live_end_case`) for
  the run host while the objective runs, with an alert dialog; removed at stop, on a host change and at resource stop.

---

### 7.4 Block notes
Each block's file header documents its fields, events and rules; the field lists are §3.3. What is not obvious from
the code:

#### Rules for every block
- Every random pick is made once with `ctx.rng` when the state is built and kept in `ctx.state` (the rng is stored
  there, so it keeps advancing); hostile_waves' low-health surrender uses `CP.Npc.rollSurrender`.
- `validate` applies the defaults to a copy and returns `false, CP.L('block.<id>.invalid.<what>', vars)`; it checks the
  `Config.Blocks` ranges, the allowed animations, the 40-armed budget, required points and `Config.Builder.noBuildZones`
  for every point, including points written into an objective (Crimson-Arena rule 7). Built-ins (`mission.source ==
  'builtin'`) are trusted on the allowed model/weapon lists, spawn-point counts and the distance from the start.
  `onEvent` reject reasons are short log ids (`too_far`, `not_held`, `wrong_state`), not locale keys.
- Every §7.1/§7.2 hook is defined. Client halves keep their state in a per-file map keyed by `runId:index`.
- Timed interactions take a `*_start` and a finish, both distance-checked, the finish at least 80 % of the duration
  later (or sampled dwell: the officer in reach for the duration minus 1.5–2 s). Progress bars still running at stop
  are cancelled. `seq`/`try` counters keep a retry from being an exact duplicate.
- Spawning runs under a re-entry flag cleared by a pcall wrapper (one failed CreatePed never freezes the objective), at
  most 8 spawns per tick, `ctx.canSpawn(1, armed)` before each one; counts are never cut. Host AI requests control
  before every task and retries on the next 500 ms loop.
- Killing a surrendered, cuffed, restrained or unarmed suspect fails the run (`run.fail_killed_unarmed`), except within
  3 s of a surrender (a shot in flight); only participant kills count. Cuffs are accepted only when
  `CP.Npc.getState(netId) == 'cuffed'` and the sender is in reach; `tick` also picks cuffs up from the bag.
- Health shares are measured above GTA's 100-point death line: `(hp - 100) / (max - 100)`.
- The server mostly sends full snapshots with `ctx.send` on every change (and once more on the first tick); clients
  write their own HUD line with `ctx.hudDetail`, rebuilt only when its text can change.

#### checkpoint_route, interact_points, skill_check
Locale `locales/parts/blocks_a.json` (also `bonus.medal_*`, `bonus.no_contact`, `bonus.devices_found_fast`); tests
`tests/blocks_a_spec.lua`.

| Block | Client → server (`ctx.report`) | Server → client (`ctx.send`) |
|---|---|---|
| checkpoint_route | `{ type='checkpoint', index, netId?, try }` · `{ type='contact', netId }` · `{ type='undriveable', netId }` | `{ kind='state', points, current, done, total, finished, medals, track={contacts,undriveable}, course={running,elapsedMs,penalty,contacts,time,medal,held} }` |
| interact_points | `{ type='interact', point, seq }` · `{ type='followup', point, seq }` · `{ type='log', point, choice }` (from the tablet) | `{ kind='state', points={ {coords,heading,label,status,outcome?,outcomeLabel?,followUp?,found?} }, hidden, found, total, done, log }` |
| skill_check | `{ type='check', target, index, success, seq }` (one per round) | `{ kind='state', targets={ {coords,netId,status,next,streak,worker} }, checks }` · `{ kind='explode', target, coords, by, effect }` |

- Ids: checkpoint_route `medal_gold|silver|bronze` and `no_contact` (medal courses only, with the EVOC card values 50 /
  25 / 10 and 10 as hints, capped for custom missions); interact_points `correct_log`, `wrong_log`, `fastBonus.id`;
  skill_check `no_missed_checks`. All shared.
- `use = 'random'` always picks a pool point inside the start first, then the pool's circular order from it.
- checkpoint_route: `timerStart = 'first'` on a first-objective medal course holds the run timer until checkpoint 1
  counts (at most 120 s; not when already paused; `course.held`). Each counted contact adds `contactPenalty` s to the
  course time and takes it off the run timer; at most one contact per 1.2 s per participant, 60 per objective. A
  `location.medals` table overrides `obj.medals`; `no_contact` also needs no server body-health loss of 10+.
  `vehicleRequired` (old files' `policeVehicle` is read as it) only requires DRIVING any vehicle, decided with server
  natives (FiveM has no server-side vehicle class). Stop time: the server's own 1 s samples must have the participant
  inside, ≤ 3 m/s, for `stopFor − 2` s; drive-through gates allow radius + 12 m. Undriveable: accepted only for the
  reporter's vehicle at engine ≤ 100 (or tank ≤ 0); the tick fails the run when a course vehicle seen healthy reaches
  engine ≤ 0.
- interact_points: a main action needs the server sample within radius + 3 m for `progress.duration − 1.5 s`, a
  follow-up likewise. `ctx.state.log = { point, choices = { { id, label } } }` (read by the view for Business Check; the
  oldest waiting door is shown); without a roll the server picks the correct log choice with equal chances. Hidden
  devices spawn when found (`role = 'device'`, `tag = 'shared:devices'`, frozen) and are appended to
  `run.shared.devices = { { netId, coords, point, model, heading } }`; the search is done once all are found and
  spawned; `fastBonus` counts from this objective's start. Custom missions: `progress.anim` an allowed name,
  `hidden.prop` `prop_ld_bomb` or `prop_c4_final_green`, `fastBonus.id` a Config.Bonuses id.
- skill_check (`targets = 'shared:devices'`): a miss repeats the round and costs `missPenalty` s; `failAfter` misses in
  a row set it off; one worker per target (freed after 15 s idle); it re-spawns a device prop that no longer exists (3
  tries) and measures from the recorded coords. The explosion `AddExplosion(x, y, z, 2, 0.0, true, false, 1.0)` (no
  damage) plays only on the client named in `by`; `onTimeout` sets off every armed device and the run fails
  `time_limit`.

#### hostile_waves, protect_rescue, flee_arrest
Locale `locales/parts/blocks_b.json`; tests `tests/blocks_b_spec.lua`. Extra evidence: `free_start`, `knock_start`,
`knock`, `aim`, `stunned`, `low_health`. Optional fields beyond §3.3: hostile_waves `boss.aliveBonus` (`{ id =
'kingpin_alive', points = 50 }`), `boss.accuracy`, `boss.behaviour`, `cuff`; flee_arrest `accuracy`, `armour`,
`cuff.maxDistance`; protect_rescue `target.icon`, `target.distance`.
- Defaults: flee_arrest scatter `suspects` 5 and `armedShare` 0.4 (§3.3; config/blocks.lua's values are Builder UI
  defaults), `knock.duration` 3000, `safeRadius` 6.0, boss health/armour `Config.Blocks.hostile_waves.health[2]` /
  `armour[2]` (400 / 100), boss weapon `WEAPON_ASSAULTRIFLE`, npcs key `'hostages'`, associates `'associates'`; text
  defaults through `CP.L` (a file's label wins).
- Waves: "alive" = not dead and not cuffed (a surrendered hostile waiting for cuffs counts); `afterSeconds` from the
  wave's start; the next wave only once the current one is fully spawned. The boss spawns after the last wave at
  `boss.spawn`, stats as written (no tier, no modifier). Besides the host's `low_health` report, `tick` polls each
  hostile's server health for its one surrender roll.
- Door mode: the response is rolled at the objective start (an armed suspect counts toward the cap) and kept secret:
  the pistol is given only at the reveal; a surrendering suspect is placed 1 m outside the door. Every flee_arrest NPC
  spawns `cfg.group = 'neutral'`.
- Escape: only fleeing or hostile suspects/inmates, beyond `escape.distance` from every participant for
  `escape.seconds`. Armed inmates: exactly `round(suspects × armedShare)`; hostile within `fireWithin`, fleeing beyond
  1.5 ×; they give up only when stunned or below `armedGivesUp.belowHealth`. `stunned`: the reporter within 50 m and a
  participant within 30 m. Lock-on aim counts for `givesUp.aim`.
- protect_rescue watches its hostages the whole run; damage comes from `CP.Npc.onDamaged` (so `shot`/`damaged` events
  change nothing while it listens); the same attacker within 1 s counts once; `no_hostage_hurt` is lost by any damage
  and recorded only after minSeconds; `hostage_hit` needs an active participant attacker. One pending Cut restraints
  per participant. The host never waits for control of a hostage another client owns (`ctx.control(ent, 0)`, retry
  after 250 ms).
- presence: nearest living hostile / hostage / suspect, else the start, safe point or door.
- Traffic (hostile_waves client): `AddRoadNodeSpeedZone`, `SetRoadsInArea` and one `ClearAreaOfVehicles` around the
  start; held while a later objective of the run exists (Secure the scene), restored when the last stops, the run ends
  or the resource stops; a later objective with the same area takes it over.
- Custom guardrails: flee_arrest `aliveBonus.id` a Config.Bonuses id without points; `boss.aliveBonus` `kingpin_alive`
  (50) or such an id; `givesUp.close` off or exactly 3 m / 3 s; knock and cuff durations 1000–30000 ms; `cuff.maxDistance`
  ≤ 3 m. The file's `aliveBonus.points` is a hint only on built-ins.

#### pursuit, escort, search_area
Locale `locales/parts/blocks_c.json`; tests `tests/blocks_c_spec.lua`.

| Block | Client → server (`ctx.report`) | Server → client (`ctx.send`) |
|---|---|---|
| pursuit | `{ type='ram', netId, speed }` (km/h, pre-impact) · `{ type='lights_near', netId }` · `{ type='aim', netId }` · `{ type='stunned', netId }` · `{ type='undriveable', netId }` (own vehicle) · `low_health`, and `cuffed` / `shot` from CP.Npc | `{ kind='state', mode, fled, trigger, lights, vehicles={ {netId,index,state,occupants,routeDone} }, suspects={ {netId,vehicle,seat,state,armed} }, detained, neutralised, total, stopped, vtotal, escaping, follow={inRange,duration,hold,lost,average} }` |
| escort | `{ type='toughened', netId }` (host only) · `cuffed` / `shot` from CP.Npc | `{ kind='state', truck={netId,driver,wp,gen,stop={at,left},arrived,toughened,health,stoppedFor,stoppedFail}, waves={ {k,triggered,done,alive} }, attackers={netId}, completed }` |
| search_area | `{ type='clue_start', clue }` · `{ type='clue', clue }` · `{ type='stunned', netId }` · `cuffed` / `shot` from CP.Npc | `{ kind='state', circle={x,y,z,r,n}, clues={ {i,x,y,z,kind,model,netId,status} }, fugitives={ {netId,state} }, checked, clueTotal, arrests, neutralised, total, entered, escaping }` |

States: pursuit cars `waiting` → `fleeing` → `stopped` | `wrecked`; pursuit peds `driving` → `stopped` → `fleeing` |
`hostile` | `surrendered` → `cuffed`, or `dead`; fugitives `idle` → `fleeing` → `surrendered` → `cuffed`; escort attackers
`hostile`, driver `driving`.
- Ids (shared): pursuit `ramPenaltyId` (`hard_ram`; Pursuit Sim `ram`) per counted ram, `detainBonus`
  (`racer_detained`) per detained suspect, `allDetainedBonus` once, `fastStop.id` (`vehicle_stopped_fast`: every car
  stopped within `fastStop.seconds` of the objective start), `medal_*` (follow mode, only after the full `duration`,
  card values as hints); escort `truck_healthy` (above 50 % at arrival); search_area `clues_first` (every clue before
  the first arrest). Completion awards are recorded before the first `ctx.complete()`.
- Added fields: pursuit `peds`, `weapons` (only with `neverShoots = false`), `detainBonus`, `allDetainedBonus`,
  `fastStop`, `failIfUndriveable`; escort `driver` (`s_m_m_armoured_01`); search_area `peds`, `witnessModel`. Defaults:
  pursuit `escape` 400 m / 20 s for stop + `all_detained`, else false; `arrest.duration` 5000; search_area `escape`
  300 m / 30 s, clue props `{ 'prop_cs_heist_bag_02', 'prop_npc_phone_02', 'witness' }`. Custom guardrails: pursuit ids
  `false`, a Config.Bonuses id or the default, `fastStop.seconds` ≤ 120; escort `driver` an allowed ped; search_area
  `clueProps` only its own, `givesUp.close` off or 3 m / 3 s; durations 1000–30000 ms; `cuff.maxDistance` ≤ 3 m.
- Pursuit start (at the objective start), placement priority: `spawns` (shuffled) > `spawn` (stacked 8 m back) >
  `trigger.ahead` > a loop route (racer i starts `2 + (i-1)` waypoints before the one nearest the intercept) > an open
  route's first point > 50 m ahead. `trigger = 'arrive' | { ahead }` flees at once; `{ distance, lights }` waits for a
  validated `lights_near`, a participant within 15 m, or body health −25.
- Stopped = below `stopped.speed` for `stopped.seconds`, counted only once the car was faster than 15 km/h (or 30 s
  after it fled) and while a participant is within 50 m; wrecked or vanished counts as stopped. Occupants are then
  told to get out (`TaskLeaveVehicle` every 2.5 s, warped out from the 3rd try) and switch to fleeing / hostile /
  surrendered only once the server sees them out (a seated suspect can be neither cuffed nor safely fled on foot).
  Give-ups: aim within 25 m of a waiting suspect (`surrenderOnAim`), aim within `flee_arrest.aimDistance` of a running
  one, stun (participant within 30 m, reporter within 60 m), or the close rule; armed ones only by stun or below 50 %.
- Completion (stop mode): every suspect cuffed or dead without a participant kill; `all_or_timeout_any` (Street Race
  Bust) also needs one detained (`onTimeout` returns completed with ≥ 1). A kill by a participant who already left is an
  outside kill, never a fail (the same for the escort driver and search_area's people).
- Rams: the ramming driver reports the touch's rising edge with the pre-impact speed; accepted in a vehicle within 12 m
  (+2), speed at most his highest server-sampled speed of the last 3.5 s + 40 km/h, once per 2.5 s per car; counted when
  `ramSpeed <= 0 or speed > ramSpeed`. A ram also makes a waiting car flee.
- Follow mode: the target is the suspect nearest the party (its car while driven); one sample per tick; `inRange` while
  ≤ `hold`; the average sets the medal; lost = beyond `lost.distance` for `lost.seconds`; undriveable as in
  checkpoint_route. If every suspect is gone without a participant kill the objective ends without a medal. `prepare`
  sets `run.flags.medals`.
- Escort: the truck spawns at `route.points[1]`; a waypoint is passed within 20 m (4 waypoints of look-ahead); a stop
  waypoint's wait never counts toward `stoppedFail`; stopped = below 1 m/s, counted only while the host is within 400 m
  (only his client drives it) and after it moved. Destroyed = death, health ≤ 0, engine ≤ −3999 or missing 2 ticks, not
  once done. Health % = min(engine, body) / (1000 × toughness after the host's `toughened`). Complete = on the final
  stretch within `arrival` of the last waypoint, every triggered wave neutralised and no living attacker within
  `clearRadius`. A participant killing the driver fails the run.
- Escort waves: `ambush.waves` at distinct random `ambushPoints` sorted along the route; a wave triggers within 120 m
  or once the truck passed its point; each car spawns with its crew when the caps allow, 7 m apart alternating 4.5 m
  left/right, doors locked, crews seated with `SetPedIntoVehicle`. Rescale drops planned waves beyond the new count.
- Search circle: `startRadius` around `location[center]`; each checked or lost clue shrinks it to the next `shrinkTo`
  with a centre within 0.7 × radius of a fugitive at large (nested when possible). Completion needs every fugitive
  neutralised. Clues: `clueCount` spots, props cycled (`witness` = a ped); `clue_start` then `clue` within 2.5 m (+2), 80 %
  of `clueProgress.duration` apart. A witness killed by a participant fails the run; otherwise a lost clue shrinks the
  circle but `clues_first` is gone. Fugitives run when a participant is within `runDistance` and escape only after
  running.
- presence: pursuit the nearest suspect (its car while driving), escort the truck, search_area the metres outside the
  circle.
- Every mission vehicle is locked (`SetVehicleDoorsLocked(veh, 2)`; peds can still get out); NPCs are unarmed except
  escort attackers (and pursuit with `neverShoots = false`).
- Driving passes the style name and m/s to `CP.Npc.task`; lap-end and stuck re-tasks pass `force = true`; the lap end
  counts only after the car got 30 m away. The host calls `ctx.control` before anything it does (re-applying and
  re-tasking when control comes back) and never waits for an entity another client owns (`ctx.control(ent, 0)`, next
  pass after 250 ms); a witness on its phone is left with the client that owns it.

#### Optional upgrades (fields in §3.3; an objective without them behaves as without them)
- pursuit: `responses` roll per vehicle from its own seed stream (every participant and re-run sees the same); `yield`
  pulls over with hazards, `fight` gets out armed (the hidden truth is armed only then). `handoff = 'contact'` counts
  occupants still seated as settled. `observe`: the officer must be behind the violator; the snapshot's `watch = {
  behind, seconds }` drives the HUD, and the violator gets its cue and blip only after passing the observation point;
  `stop_without_cause` (−15) is personal. Drive-by: a passenger targets the nearest participant within 40 m; a boxed-in
  fight car rams once, only a participant. Stats `vehicles_stopped` and `noteArrest` per cuff.
- interact_points: `together` needs `min(count, participants)` distinct officers within `window`; a stale or repeated
  hold resets with a HUD line. `hidden.kind = 'seize'` has no prop; finds note the `evidence` stat and
  `run.shared.evidence`. `fastBonus.after = 1` (the raids) counts `stash_found_fast` from the breach.
- skill_check `onFail.setback`: the recovery is a sampled dwell finished by a `'recover'` report; the retry is timed
  from its end; the state sends `setback` and `retryIn`.
- flee_arrest: a compliant or nervous inmate who scatters surrenders; the feint is rolled at the first surrender and
  the client reports aim; killing a feinting suspect still fails; `custody = 'handover'` counts only once handed over.
- hostile_waves `spawnSets` names the chosen sets in `run.shared.intel`; protect_rescue notes `rescues` at the safe
  marker; flee_arrest and hostile_waves `noteArrest` per cuff.

#### field_contact (blocks/field_contact)
Defaults also `transport = 'transport'`, `models`, `vehicles`, `weapons`, `aliveBonus = { id = 'subject_alive' }`,
`allCorrect = { id = 'all_correct' }` (valued by Config.Bonuses).
- parked: `cars` random kerb spots of the location's `spots`; each car rolls the set's vehicle truth (a free spot never
  a violation; level from `Config.Custody.parkingRules[rule]`). Returning driver (at most `returning.max`,
  `returning.chance` per cite or impound of a car that is not stolen): takes the ticket 60 %, argues until Explain the
  citation 30 %, drives off 10 % (cites only). The thief (`thief.chance`, on the first inspect of a stolen car) waits
  30 m away and runs once an officer is within `thief.runAt`.
- scene: a variant from `scene` (occupied_car, loitering, casing); the first participant within `approach` sets people
  off by demeanour (evasive walk_away, runner flee_on_approach, hostile tell_then_draw; compliant and nervous stand). A
  consensual contact may leave: walking beyond the escape distance costs nothing.
- stop: takes the `run.shared.contacts` entries owned by this objective, in the pursuit block's format `{ vehicle,
  occupants = { { netId, seat, state, truth } }, observed = { kind, speed, zone }, forced, profileSet, truth, taken }`
  (occupant state fleeing/cuffed = ran on foot; forced = PIT or box-in, everyone Evading; observed gives the driver a
  violation). `revealed = { 'stolen' }` on the objective makes the plate known (Stolen Vehicle Takedown). A person the
  pursuit spawned unarmed but rolled armed gets armedTruth and a hidden weapon.
- Runners and walkers give up when aimed at within 10 m (`aim`), stunned, or with a participant within 3 m for 3 s. A
  runner or drawer cuffed through Cuff suspect is that officer's arrest and earns aliveBonus once; their Arrest
  decision is then Best with 0 points.
- Escape (beyond `escape.distance` for `escape.seconds`): `escapeFails` fails the case, else `missed_arrest` (shared).
  Killing a person who never drew fails the case (`run.fail_killed_unarmed`).
- `vehicle_impounded` (shared, `each`) for each car lawfully impounded when the card lists it.
- Complete when every contact is decided (an Arrest handed over with `custody = 'handover'`), dead or gone, and any
  returning driver is done; then `all_correct` (every decision Best) and `procedure_complete` per officer (everyone he
  arrested was ID-checked and searched). On the time limit undecided contacts count as missed. A car removed by
  sc-police `/imp` is gone, never an Impound.

#### process_scene (blocks/process_scene)
prepare: `CP.Runs.holdBodies(run, { roles, max = bodies })`. start: `pauseFastClock`; no bodies → aliveBonus and it
completes at once (minSeconds 0). Else the coroner van goes to the location's `coroner` point (or the scene) unless
`coroner = false`. Client reports `tag_begin`/`tag`, `bag_begin`/`bag` (a body within 2.5 m), `release_begin`/`release`
(the parked van within 6 m, or the scene without a van); each finish needs the step's duration (−0.5 s) and the
officer in reach for it minus 2 s. Bag releases the body and spawns the bag prop; Release deletes the bags and sends
the van. ox_target names `crimson-police:body_tag`, `body_bag`, `coroner`.

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
| `client:routeStatus` | runId, status (`'arrived'`; `'action'` once for a late partner: CP.Runs then calls `CP.Route.follow`) | route, runs |
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
| `client:builder:teleport` | `{ missionId, location, key, index, coords }`: the answer to the caller's own `server:builder:teleport` (the stored point's coordinates; the client ignores one it did not ask for) | builder |
| `client:objective` (new action) | runId, index, `{ action = 'adopt', op = 'adopt', netId, obj, from }`: the host moves the AI of netId to objective obj's client half | runs |
| `client:missionCall` | `{ id, code, typeLabel, priority, areaLabel, paged?, live?, title?, street? }` (live: a LIVE call) (toast and tone; the client drops it when muted, on a run or in the arena) | missioncalls |
| `client:liveJoinOffer` | `{ runId, token, title, street, seconds }` (the yes/no pop-up to join a live case; one at a time, closed after `seconds`) | livecrime |
| `client:liveSurrenderAsk` | `{ token, seconds, talk }` (a live suspect's surrender question, his own command or an officer's Talk them down; closed after `seconds`) | livecrime |
| `client:readyCheck` | `{ typeKey, typeLabel, expiresIn, leaderName, twists = { { key, label } }, live? = { title, street, suspects } }` (live: a live case's LIVE line) or nil to clear | units |
| `client:contactAct` | `{ runId, netId, behaviour, args, seconds }` to the run host only, when the behaviour starts | custody |
| `client:contactConfirm` | `{ netId, choice, factKey }`: open the tablet with the case-fail confirm | custody |
| `client:serviceVehicle` | `{ runId, id, op = 'drive'|'load'|'leave', kind, veh, driver, dest, target, away }` to the driving client | custody |
| `client:serviceBlip` | `{ runId, id, kind = 'prisonerVan'|'towTruck', show, netId, coords }` to every active participant when a transport van's or tow truck's status changes (show while coming, parked or loading), and to a late partner at `run:arrived` (§5.44 `service`, Config.Markers.serviceVehicles) | custody |
| `client:closeTablet` | errKey (requireItem: the item left the inventory) | tablet |
| `client:missionBlips` | `{ runId, items = { { k, p, n?, s?, x, y, z } } }` to an officer when his extra mission blips change; an empty list clears (§5.53, Config.MissionBlips) | missionblips |
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
| `server:liveJoin` | runId, token, yes (three args, no reqId; 3 a second; only the token of a live offer that has not run out joins, through `CP.Runs.addParticipant`) | livecrime |
| `server:liveSurrender` | token, yes (3 a second; only the suspect's own open question, checked again: free, not down, an officer of the case within `surrenderRange`) | opponents/surrender |
| `server:liveTalkDown` | none (2 per 2 s; an active officer of an open live case, the nearest free suspect within `talkRange` by server coords) | opponents/surrender |
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
| `server:tabletClosed` | — (plain event, once per close; 4 per s): ends the `nav` watch, fires `tablet:closed` | tablet |
| `server:mcWatch` | false = the tablet closed (plain event; deprecated, not sent: `server:tabletClosed` replaces it) | missioncalls |
| `server:claimMissionCall` | `{ callId, twists? }` → `{ runId }` or `{ pending }` (the twists are checked before the claim joins the window) | missioncalls |
| `server:declineMissionCall` | `{ callId }`: the paged unit's leader turns a pushed mission down | missioncalls |
| `server:contactDecide` | `{ runId, netId, choice, offence?, confirmed? }` → `{ ok }` or `{ confirm = { factKey } }` | custody |
| `server:profile:set` / `server:profile:report` | see §5.32 | profile |
| `server:options:set` | `{ key = value, ... }` → `{ values }` (rate 4; see §5.48) | options |
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
`police:server:BobbyPinResult` and `police:server:SeizeCash` (CP.ScPolice.on listeners, real suspects);
`hospital:server:RespawnAtHospital` (CP.Ambulance.on listeners). The real-suspect handlers do nothing while no case with a
real suspect is open; their consumers are the proof step (§5.45) and the conduct step (§5.45: 'seizeCash'),
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
Also: `getMissionCalls`, `getNavCounts`, `getOptions` (§5.48), `getProfileEdit`, `getRewardsLocker`, `sup:getMissionCalls`,
`sup:getProfileQueue`, `admin:getRewards` (`{ page }`), `admin:getAreaCoverage`, `admin:getLocationStats`
(`{ missionId }`), `admin:getOfficerProfile` (`{ citizenid }`), `admin:getConfigHealth`, `admin:getTabletAccess`,
`admin:getSettings`, `admin:getSettingsHistory` (`{ page, path? }`), `sup:getMissionControls`, `sup:getMyControls`,
`sup:getDeptNotices` (§5.49), `sup:getOfficerCooldowns` (`{ citizenid }`) and `admin:getMissionControls` (§5.49; rate 3);
`getBoard` gains `metric`, `getSession` gains `via` and `desk`.

Actions (write), each checks `CP.Permissions.can`:

| Action | Payload | Permission | Owner |
|---|---|---|---|
| `server:sup:setTypePayout` / `server:admin:setTypePayout` | `{ type, amount (nil=clear, admin), reason }` | setTypePayout / admin | payouts |
| `server:admin:setMissionPayout` | `{ missionId, amount (nil=clear), reason }` | setMissionPayout | payouts |
| `server:sup:setMissionControl` / `server:admin:setMissionControl` | `{ key, value, reason, requestId, department? (admin) }` → `{ department, key, value }` (rate 2; §5.49) | missionControls (supervisor: own department) / admin | deptcontrols |
| `server:sup:resetMissionControl` / `server:admin:resetMissionControl` | `{ key, reason, requestId, department? (admin) }` → `{ department, key }` | missionControls / admin | deptcontrols |
| `server:sup:clearCooldowns` | `{ citizenid, scope = type\|mission, key, reason }` → `{ used, max }` (§5.49) | Mission control clearCooldown | livectl |
| `server:sup:postNotice` / `server:sup:endNotice` | `{ text, days, reason? }` → `{ id, department }` / `{ id, reason? }` → `{ id }` (§5.49) | Mission control notices (own department) | deptnotices |
| `server:sup:addRunTime` | `{ runId, minutes, reason }` → `{ runId, timeAdded }` (§5.49) | Mission control addRunTime (own department) | livectl |
| `server:sup:opLaunch` / `server:admin:opLaunch` | `{ missionId }` | launchCrossDept | operations |
| `server:sup:opStart` / `server:admin:opStart` | — | launchCrossDept | operations |
| `server:sup:opRelaunch` / `server:admin:opRelaunch` | — | launchCrossDept | operations |
| `server:sup:opCancel` / `server:admin:opCancel` | `{ reason }` | launchCrossDept | operations |
| `server:sup:forceRecall` | `{ runId, src }` | forceRecall | admin |
| `server:sup:reviewFlagged` / `server:admin:reviewFlagged` | `{ rowId, decision = 'approve'|'void', reason }` (a supervisor's first Void under reviewRules.secondVoid → `{ rowId, pending = true }`) | reviewFlagged | admin |
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
| `server:builder:teleport` | `{ missionId, location, key, index }` → `{ missionId, location, key, index }` + `client:builder:teleport` with the stored point (no coordinates are accepted from the client) | builderEdit + `Config.Builder.teleport` + admin or a `Config.Permissions.builderTeleport` grant (department, grade) | builder; refused in the arena, on a run, while down; audit `builderTeleport` |
| `server:sup:mcWithdraw` / `server:admin:mcWithdraw` | `{ callId, reason }` | missionCalls | missioncalls |
| `server:sup:mcPage` / `server:admin:mcPage` | `{ type, area, leaderSrc, missionId? }` (missionId: the pushMission control) | missionCalls | missioncalls |
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
| `server:sup:awardPoints` | supAction | missionControls (DC.canChange awardPoints) | `{ citizenid, points (the department's min..max), reason, confirm? }` | R S(strict) L(1 per 10 s per officer); T as above; a supervisor: own department, `awardPointsPerDay` from today's rows; then `CP.Corrections.adjust` |
| `server:sup:ftoPair` / `server:sup:ftoUnpair` | supAction | viewMissionList (own department; Config.FieldTraining.enabled) | `{ rookie, trainer }` / `{ rookie }` | S on the rookie; audit `ftoPair` / `ftoUnpair` (§5.50) |
| `server:fto:signOff` | action | the rookie's own trainer | `{ rookie, task, note? }` | a ready task, once; audit `ftoSignOff`; the last one gives the badge (§5.50) |
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
| `admin:getRsCases`, `admin:getRsCase`, `admin:getRsPairs` | callbacks | antiFarmOverride | `{}` / `{ runUuid }` / `{ citizenid? }` | modules/opponents/staff; server-only case data, refused for the admin's own case |
| `server:admin:rsBlockPair`, `rsExclude`, `rsSuspend` | actions | antiFarmOverride | `{ officer, suspect, days, reason }` / `{ citizenid, days, reason }` | 0 < days <= 3650, never his own characters, `err.rs_off` while both features are off |
| `server:admin:rsLift`, `rsClearStrikes` | actions | antiFarmOverride | `{ kind, officer?, suspect?, reason }` / `{ citizenid, reason }` | never his own characters, `err.rs_no_row` / `err.rs_no_strikes` when nothing is running |
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

Guards: P = permission key, I = request id, R = reason, T = typed word, V = preview token,
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
| `server:admin:setTypePayout` (existing) | gains `unlock?: boolean` | setTypePayout | unchanged |
| callback `admin:getRewards` (existing) | gains `{ citizenid?, status?, source?, from?, to? }` | openAdmin | unchanged |
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
| `admin:getRefusals` | — → `{ refusals: { at, citizenid?, name?, missionId?, missionLabel?, type?, reason }[], total, today }` | openAdmin | `today`: the kept ones on the server's day (CP.Schedule.dayStart); shown on Live → Refused and Home → Something wrong?; memory only (CP.Refusals, shared/init.lua): the last `AdminControl.refusalsKept` refused mission starts, newest first; kept by the Mission Board accept (CP.Draw.accept) and by CP.Runs.create for Operations and Testing |
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

### 8.5 This PC: officer options (modules/options/client.lua)

- Client actions (NUI `client` endpoint): `getLocalOptions` -> `{ options }` (every 'local' option and its value now);
  `setLocalOption` `{ key, value }` -> `{ key, value, options }` (the clean value; errors `err.invalid_payload`,
  `err.option_locked`, `err.option_value`).
- NUI message `{ type = 'localOptions', options }` on the NUI `ready` and after every change of this PC's values.
- Hook `options:changed (key)` (client): an option's value changed (the session, the push `options`, or this PC).
- Client action `getKeyLabels` (modules/tablet/client.lua) -> `{ keys = { { command, state, label } } }` for
  `crimsonpolice_tablet`, `crimsonpolice_dispatch`, `crimsonpolice_ready` and `crimsonpolice_contact`, in that order:
  `CP.Tablet.keyLabel(cmd)` reads `GetControlInstructionalButton(0, joaat(cmd) | 0x80000000, true)`; `'t_F5'` ->
  state `set`, label `F5`; `'b_<n>'` -> `other` (a mouse or pad button); anything else or a failing native -> `unset`.
  `Config.OfficerOptions.enabled = false`: `err.option_locked`.

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
| `push` | `topic`, `data` | live data for open screens: `run`, `unit`, `board`, `operation`, `invites`, `test`, `builder`, `payouts`, and `calls` (DispatchView), `nav` (NavCounts), `profile` (own profile changed), `options` (own officer options changed, `{ values }`), `rewards` (locker changed), `contactConfirm`, `settings` (admins: a setting or switch changed, `{ paths }`), `missionControls` (a department's supervisors and the admins: a Mission control changed, `{ department, key }`, §5.49), `spawnCheck` (the admin's spawn point check, §5.27), `reviewQueue` (Config.Tablet.supervisorReviewLive: another supervisor or an admin decided a flagged run or a dispute; the viewer's own ReviewQueue, only while his Review Queue is open); `unit` gains `readyCheck`, `run` gains `contact` |
| `overlay` | `overlay = null \| { kind: 'placement'\|'recording'\|'testdrive'\|'fade', ... }` | full-screen/HUD overlays |
| `theme` | `theme`, `locale?`, `prefs?`, `options?` | the department theme for the HUD (login, duty, job, unload, and a change of the options `hudLook` / `textSize`), with the officer's look (`prefs` { appearance, accent }, `options` { hudLook, textSize }; absent without an officer session); only the reply to `ready` carries `locale` (`CP.Locale.all()`), the NUI's one copy of the text |
| `locale` | `locale` | the whole locale again after `Config.Labels` changed (an open tablet shows the new names at once) |
| `localOptions` | `options` | this PC's 'local' officer options (§8.5): on `ready` and after every change |

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

Safety nets: `QuietBoundary` (renders nothing for the broken part) wraps the HUD column, HUD, result card, debug
overlay, overlays, toasts and each layout; a crashed layout or an `open` that cannot be shown calls `close`; the root
boundary calls `close` and mounts the app again after 2 s (sending `ready` again, at most 3 times). An older build
without `acks` is never closed by the 6 s open check (§5.4).

Replies that carry their screen's view (`shared/replyView.ts` applies `data.view` / `queue` / `activity` / `runs` /
`officer`; the screen asks again only when it is missing): `server:sup|admin:reviewFlagged` and `handleDispute`
(`queue`, `CP.Admin.reviewQueueFor`), `server:declineMissionCall` (`MC.list`), `server:sup|admin:mcWithdraw|mcPage|
mcCreate` (`MC.supView`), `server:sup:forceRecall` and `addRunTime` (`CP.Admin.liveRunsFor`), `server:sup:
clearCooldowns` (`CP.LiveCtl.supCooldownsView`), `server:sup:commend|revokeCommendation|missionBan|liftMissionBan|
awardPoints` sent with `activityOf` (`activity`, `CP.Challenge.supActivity`), `server:admin:voidRun|restoreRun|
setVoidKind|flagRow` sent with `views = { rowId, archived, citizenid, runs, officer }` (`CP.Corrections.withViews`),
`server:admin:backupNow|restoreBackup|deleteBackup` (`Sys.backupsView`), `storageCopy|setStorageMode|useStoreAgain`
(`Sys.storageView`; `admin:getStorage` allows one read per 5 s), `server:admin:resetAllSettings` (`Settings.all()`).
`Config.Tablet.supervisorReviewLive` (false): after each review decision `CP.Admin.shareReviewQueue(src)` pushes
`reviewQueue` to the department's other supervisors who asked for the queue in the last 75 s.
`Config.Tablet.supervisorRemember` (false): supervisor dialogs open with the values last used
(`supervisor/components/lastUsed.ts`, page memory only).

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

More session fields (web/src/shared/types.ts, verbatim there; all optional):

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
                                                   // 'action': a late partner follows the objective
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

More screen data lives in its own type files (the Lua side follows them exactly):
`web/src/types/missioncalls.ts` (DispatchView, MissionCall, RecentCall, SupCallsView, AreaCoverage), `types/custody.ts`
(ContactView, ContactEntry, ContactConfirm), `types/profile.ts` (ProfileEdit, Commendation, ServiceStats,
ProfileQueueItem), `types/boards.ts` (the metric boards and profile additions), `types/teams.ts` (UnitView and
OperationView additions), `types/rewards.ts` (RewardRow, RewardsLocker, AdminRewardsView), `types/access.ts`
(TabletAccessView), `types/settings.ts` (SettingView, SettingsData, SettingsReply, SettingsHistory, MissionSwitchView) and
`types/run_ui.ts` (DecisionEntry, DecisionFact, DebriefPerson, RunProgress, RunStats,
RunMissionCall, RunItem and the
ActiveMissionView extras intel, missionCall, contact and live (LiveCaseView)). BoardData gains `callsOpen` and daily locks; HomeData
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
  // admin/components/OfficerRunControls, OfficerSupport, in Officers → officer detail
interface DepartmentSlotProps { department: string }          // DepartmentFunds, each department card
interface RewardPoolSlotProps { path: string; value: unknown; disabled?: boolean; onSave: (v: unknown) => unknown }
  // RewardPoolEditor with handlesRewardPool(path): Settings uses it for the paths it handles
// MissionsToday (no props): Missions → catalog tab
```

Missions and the Mission Builder (web/src/types/admin_missions.ts): `OverrideView` (builder:list `builtins[].override`,
`BuilderListEntry.override`: overridden, shippedHash, baseHash, version, hasDraft, status, tweaks, loadError?, changed),
`BuiltinDiff`, `VersionDiff`, `MissionLoadSummary`, `MissionTweakView`, `SwitchRemapData`, `Paged<R>` with
`OperationHistoryRow` / `DispatchHistoryRow`, `MissionStatsData`, `DeletedMission`, `ImportPreview`, `TestHistory`.
`TestLocationStatus` gains `checked`; `TestMissionRow.switch` is the mission's `MissionSwitchView`. The admin pieces
of Admin UI → Missions live in `web/src/builder/admin/`.

Live runs, units and anti-farm (web/src/types/admin_live.ts):

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
`admin_live`, `admin_system`.

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

System (web/src/types/admin_system.ts): StorageView, StorageCopyReply, BackupView, BackupsData, RestorePreview,
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
  // more sections, each shown only when present (older rows lack them)
  decisions?: DecisionEntry[]; people?: DebriefPerson[] | null; progress?: RunProgress | null; stats?: RunStats;
  missionCall?: RunMissionCall | null; items?: RunItem[];
  live?: { title?: string; street?: string; open?: boolean; outcomes?: { label: string; outcome: string }[] } | null }
// live: a live case, each suspect's outcome by label once it is over (§5.46 "The officers' tablet")
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
  `block.<id>.*`, `modifier.<key>`, and `mc.*`, `custody.*`, `bonus.*` additions, `rewards.*`.
- Optional label overrides (`CP.Locale.label`, `CP.Missions.label`): `type.<key>` (e.g. the ready-check prompt),
  `mission.<id>.label`, `mission.<id>.description`, `mission.<id>.location.<n>`. A missing key uses the text from
  config or the mission file, so custom missions keep the builder's text.
- English only: `locales/en.json` is the only language file. Text for a player's screen that is
  built on the server may be sent as a `CP.Lt(key, vars)` token (§2); it resolves in the server language. There is no per-player language (no column, preference, list or picker).
- The UI reads the same strings via `t(key, vars)`: the client sends them once with the reply to `ready` (the
  `theme` message) and again as `locale` after a `Config.Labels` change. Sessions carry no locale.

## 11. Verification (every change must pass)

`tools/check_all.sh` runs every check below in one command; `docs/TESTING.md` covers the set-up and how to
read a failure.

- `luac5.4 -p` on every Lua file it wrote.
- `python3 tools/lint_fivem.py`: the FiveM pitfall rules (wrong-side natives, late `source`, client `os`/`io`,
  unguarded focus release, raising callback awaits, orphan mode, `os.rename` answers, server `os.execute`,
  the Crimson-Arena natives, loops that can go round with no Wait (FX10, `tools/lua_flow.py`), debug functions FXServer
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

---

## 12. Web UI developer guide

For developers only: server owners never build the UI (the root `README.md`, section 12, says why).

React 18 + TypeScript + Vite 6, in `Crimson-Police/web/`. Builds into `web/dist`, which FiveM loads as
`ui_page 'web/dist/index.html'` of the resource **Crimson-Police**. `dist/` is committed, so rebuild
and commit it after every UI change.

One page holds everything: the Officer and Supervisor UIs (a tablet in the department theme), the
Admin UI (a full-screen panel in the admin theme), the mission HUD, the result card, toasts and
overlays. The page itself is fully transparent (the game is drawn behind it) and renders nothing
while nothing is active.

```
cd Crimson-Police/web
npm install
npm run dev         # browser dev mode on http://localhost:5173 (mocks + dev panel)
npm run build       # tsc --noEmit && vite build && node build-stamp.mjs → dist/ (zero errors; writes dist/build-stamp.json)
npm run typecheck
```

The gate (`bash tools/check_all.sh`, docs/TESTING.md) runs `tsc` and rebuilds the sources in a scratch copy:
`web/dist` must be byte-identical to that build. `tools/check_contracts.py` also fails when `dist/` was not
rebuilt after a change to `web/src/` or `locales/parts/`.

No component libraries, CSS frameworks or router: plain CSS with CSS variables, a state-based screen
switch, and no remote fonts or URLs anywhere (FiveM may be offline).

### 12.1 Layout of `src/`

```
main.tsx                  boot: loads mocks in browser mode, renders <App/>
App.tsx                   all Lua-driven state (session, ui, hud, result, toasts, overlay, theme)
shared/
  types.ts                every NUI shape (§9.2–9.6) + Notification, Overlay, UiKind, ApiResult
  nui.ts                  the bridge: fetchNui, request, action, clientAction, useNuiEvent, registerMock, emitDebug
  hooks.ts                useRequest, useAction, useCountdown, usePush, useEscapeLayer, useViewport …
  i18n.tsx                LocaleProvider, t(), useT(), tOr(), hasKey()
  theme.ts                applyTheme(), themeVars(), DEFAULT_THEME, colour helpers
  session.tsx             useSession(), useCan(), useTablet(), officerLine()
  navigation.tsx          useNavigate(), useNavigation(), ScreenKey
  data.ts                 asArray() and other guards for lists that Lua may send as {} or leave out
  format.ts toast.ts cx.ts
  components/             the shared toolkit (index.ts exports everything)
  index.ts                re-exports all of the above: import { … } from '../../shared'
layouts/                  TabletFrame, Header, Sidebar, RunBar, NotificationBell, ScreenHost, navBadges,
                          Officer/Supervisor/AdminLayout, screens.ts (the screen registry)
officer/screens/          Home, MissionBoard, Dispatch, Unit, ActiveMission, Leaderboard, Challenge, Profile
supervisor/screens/       MissionList, CrossDept, LiveMissions, ReviewQueue, Payouts, Builder, DeptReport
admin/screens/            Payouts, Missions, Seasons, Leaderboards, Officers, Departments, Permissions, Settings, Audit,
                          Testing
hud/                      Hud, HudColumn, ResultScreen, Debrief, ContactCard, FadeOverlay, TestControls, DebugOverlay,
                          BuilderOverlay
mocks/                    browser-only: index.ts (loads every *.mock.ts), core.mock.ts, one <feature>.mock.ts per
                          package, samples.ts, DevPanel, Gallery
styles/                   base.css (tokens), components.css, layouts.css, hud.css
```

### 12.2 Adding or changing a screen

Each screen is **one file** with a default export and no props. `layouts/screens.ts` is the registry: sidebar
order, title key, icon and visibility. The layouts and the sidebar read it, so a new screen is its file, its key in
the `*ScreenKey` types of `shared/navigation.tsx` and one registry entry.

Admin UI screens and the Supervisor Mission Builder are registered with `lazyScreen(ui, () => import(...))`:
their code is a chunk of its own, loaded when that UI opens (`preloadScreens`), so a player's NUI starts
without it. A new Admin UI screen does the same. A new stylesheet is also listed in `styles/order.ts` (every
stylesheet loads with the page, in that order; `tests/nui_bundle_spec.lua` checks the list and the size of the
start-up script).

1. **The screen file.** Keep the default export and no props:

   ```tsx
   import { Screen, Card, Table, Button, Money } from '../../shared/components';
   import { useRequest, useAction } from '../../shared/hooks';
   import { t } from '../../shared/i18n';
   import { useNavigate } from '../../shared/navigation';
   import type { BoardData } from '../../shared/types';

   export default function MissionBoard() {
     const { data, loading, error, refetch } = useRequest<BoardData>('getMissionTypes', {}, { pushTopic: 'board' });
     const { run, busy } = useAction();
     const navigate = useNavigate();
     const accept = async (type: string) => {
       const res = await run('server:acceptType', type, { success: 'board.accepted' });
       if (res.ok) navigate('active');
     };
     return <Screen title={t('ui.screen.board')}>…</Screen>;
   }
   ```

   Screen keys (for `navigate`) and title keys (`ui.screen.<key>`):

   | UI | keys (sidebar order) |
   |---|---|
   | Officer | `home` `board` `dispatch` (hidden when `Config.MissionCalls.enabled = false`) `unit` `active` `leaderboard` `challenge` `profile` |
   | Supervisor | `sup_missions` `sup_crossdept` (launchCrossDept) `sup_live` (+ minutes: addTime) `sup_controls` (missionControls, or `session.config.missionControls`; happy hour: Start with minutes, countdown, End now) `sup_review` (reviewFlagged or handleDisputes) `sup_payouts` (setTypePayout) `sup_builder` (builderEdit) `sup_report` (officer dialog: Clear cooldown) |
   | Admin | `admin_home` `admin_payouts` `admin_payments` `admin_missions` `admin_live` `admin_seasons` `admin_leaderboards` `admin_officers` `admin_departments` `admin_permissions` `admin_settings` `admin_system` `admin_audit` `admin_testing` `admin_rs` |

   `navigate(key, params)` passes params; read them with `useNavigation().params`
   (e.g. Leaderboard → `navigate('profile', { citizenid })`). Keys of another UI are ignored.

2. **Mocks** for browser mode go in a new file `src/mocks/<feature>.mock.ts`. Every `*.mock.ts` is
   loaded automatically:

   ```ts
   import { registerMock } from '../shared/nui';
   import { sampleResult } from './samples';
   registerMock('request', 'getProfile', (citizenid) => ({ …, runs: [{ …, breakdown: sampleResult('completed') }] }));
   registerMock('action', 'server:acceptType', (type) => {
     if (type === 'tactical') throw new Error('err.server_busy');   // → { ok: false, error: 'err.server_busy' }
     return { runId: 'x' };
   });
   ```

   A mock returns the data (or a Promise); throwing an `Error('err.<key>')` answers with that error.
   `core.mock.ts` registers `getSession`, a fallback `getRun` (overridden by any real `getRun`
   mock) and `logoFailed`.

3. **Text** goes in your own locale part `Crimson-Police/locales/parts/<slice>.json` (flat JSON
   object, your namespace from §10). Never hard-code English; never edit another
   slice's part. Browser mode merges every part automatically. In game only `locales/en.json` is
   loaded: regenerate it with `python3 tools/check_contracts.py --merge` and commit it (the check fails
   while it is missing or out of date).

4. **Styles**: put screen CSS in a sibling file (e.g. `officer/screens/MissionBoard.css`) imported by
   your screen, prefix classes with your feature (`.board-…`) and use only the `--cp-*` variables
   below so every department theme works.

5. Run `npm run build` (zero TypeScript errors) and commit `dist/` with its `build-stamp.json`.
   `tools/check_contracts.py` fails when `dist/` was not rebuilt after a change to `src/`.

### 12.3 NUI transport (§9.1)

**Lua → NUI**: `SendNUIMessage({ type = …, … })`, received as window `message` events.

| type | fields | effect |
|---|---|---|
| `open` | `ui`, `session`, `screen?` | show that UI (optional screen key to open) |
| `close` | — | hide the UI (HUD stays) |
| `session` | `session` | replace the session |
| `notify` | `notification = { id, kind, title?, text, duration, bellOnly? }` | toast (text already translated); `bellOnly`: only the bell lists it (quietRun on a run) |
| `hud` | `hud = HudState \| null` | mission HUD (full state; null hides) |
| `result` | `result = RunResult \| null` | result card for the officer option resultTime, 25 s shipped (null hides) |
| `push` | `topic`, `data` | live updates: `run` `unit` `board` `operation` `invites` `test` `builder` `payouts` `calls` `nav` `profile` `rewards` `settings` |
| `overlay` | `overlay = null \| { kind, … }` | `fade { text }`, or builder kinds `placement` `recording` `testdrive` |
| `theme` | `theme`, `locale?` | the officer's department theme (HUD/toasts) at login, duty, job and unload; only the reply to `ready` carries the locale, the NUI's one copy of the text (a session has none) |

**NUI → Lua**: `POST https://<GetParentResourceName() or 'Crimson-Police'>/<endpoint>` with JSON.

| endpoint | body | reply |
|---|---|---|
| `ready` | `{}` | `{ ok }` — sent once on mount |
| `close` | `{}` | `{ ok }` — Escape (when no dialog is open) or the close button |
| `request` | `{ name, args }` | `{ ok, data?, error? }` — callback `crimson-police:<name>` |
| `action` | `{ name, payload }` | `{ ok, data?, error? }` — net event `crimson-police:<name>` |
| `client` | `{ name, payload }` | `{ ok, data?, error? }` — `CP.Tablet.registerClientAction` |
| `switchUi` | `{ ui }` | `{ ok, data: Session }` |

Client actions the foundation calls: `logoFailed { department, url }` (once per failing logo URL).

Bridge API (`shared/nui.ts`), all resolving (never rejecting) to `{ ok, data?, error? }`:

- `request<T>(name, args)`, `action<T>(name, payload)`, `clientAction<T>(name, payload)`, `fetchNui<T>(endpoint, body)`
- `useNuiEvent(type, handler)` — handler gets the whole message (`m.hud`, `m.topic`, …)
- `isEnvBrowser()`, `resourceName()`, `registerMock(kind, name, fn, { fallback? })`, `emitDebug(type, fields, delayMs?)`
- Network failures map to `err.no_response`, 20 s without a reply to `err.timeout`.

### 12.4 Hooks (`shared/hooks.ts`)

| hook | returns / does |
|---|---|
| `useRequest<T>(name, args, { pushTopic?, pollMs?, skip? })` | `{ data, loading, error, refetch, setData }`; refetches when `args` change (by value), on push `pushTopic` and every `pollMs`; keeps old data while refetching |
| `useAction()` | `{ run(name, payload, { success?, successVars?, silent? }), busy }`; failed actions toast `t(error)` |
| `useCountdown(seconds, { paused?, resetKey?, onDone? })` | seconds left, counting down locally; restarts when `seconds`/`resetKey` change |
| `usePush(topic, handler)` | handler(data) for each `push` of that topic |
| `useEscapeLayer(active, onEscape)` | Escape closes this layer before the UI (Dialog uses it) |
| `useViewport()`, `useHudScale()`, `usePrevious()` | helpers |

Session and navigation: `useSession()` (the Session), `useCan()` → `can('forceRecall')`,
`useTablet()` → `{ close, switchUi, refreshSession, ui }`, `useNavigate()`, `useNavigation()`.

Text: `t(key, vars)` (module level, also fine in components) replaces `{var}`; unknown keys render
the key. `useT()` is the hook form, `tOr(key, fallbackKey)` picks a fallback key, `hasKey(key)`.

Formatting (`shared/format.ts`): `formatMoney(1040)` → `$1,040`, `formatNumber`, `formatMultiplier`
(`×1.30`), `formatDuration` (`8:02`), `formatDistance`, `formatPercent`, `formatDateTime`.
Toasts from code: `toast(kind, text, { title?, duration? })` (`shared/toast.ts`).

### 12.5 Theme variables

`applyTheme(el, theme)` (`shared/theme.ts`) validates 6-digit hex per key (default: the
Crimson-Police theme `#a4161a / #e5383b / #0b090a / #161a1d / #f5f3f4`) and sets:
`--cp-primary --cp-accent --cp-bg --cp-surface --cp-text`, derived `--cp-surface-2 --cp-surface-3
--cp-border --cp-border-strong --cp-muted --cp-subtle --cp-primary-contrast --cp-accent-contrast
--cp-primary-hover --cp-primary-text --cp-accent-text`, and `--cp-*-rgb` triplets for `rgba()`.
Fixed tokens: `--cp-success/warning/danger/info` (+ `-rgb`), `--cp-xp-<badge>`, `--cp-tier-<tier>`,
`--cp-radius*`, `--cp-fs*`, `--cp-shadow*`. Numbers use the `.cp-num` class (tabular figures).
Avoid `color-mix()`, CSS nesting and `:has()` (FiveM's CEF may be older).

### 12.6 Components (`shared/components`)

| Component | Props |
|---|---|
| `Button` | `variant` primary\|secondary\|ghost\|danger, `size` sm\|md, `loading`, `icon`, `iconRight`, `block`, button attrs |
| `IconButton` | `icon`, `label` (required, aria + tooltip), `variant`, `size`, `loading` |
| `Card` | `title`, `subtitle`, `icon`, `actions` (header slot), `footer`, `padding` none\|sm\|md\|lg, `highlight` primary\|accent\|success\|warning\|danger, `muted`, `onClick` (becomes keyboard-clickable) |
| `Screen` | `title`, `subtitle`, `help` (one muted line under the subtitle), `actions` — standard page wrapper for every screen |
| `Section` | `title`, `description`, `actions` |
| `Grid` / `Stack` / `Row` / `Spacer` / `Divider` / `KeyValue` | `Grid cols={3}\|"2fr 1fr"`, `min={220}` (auto-fill), `gap` (4px steps); `Stack direction gap align justify wrap grow` |
| `Badge` | `tone` neutral\|primary\|accent\|success\|warning\|danger\|grey\|bronze\|silver\|gold\|platinum, `variant` soft\|solid\|outline, `size`, `icon`, `dot` |
| `TierBadge` | `tier` (standard…critical), `label?`, `expected?`, `size` |
| `XpBadge` | `badge` (Config.XPLevels colour), `label` |
| `Tabs` / `SegmentedControl` | `items [{ key, label, icon?, badge?, disabled? }]`, `value`, `onChange`; arrow keys move |
| `Table` | `columns [{ key, header, render?, width?, align?, numeric? }]`, `rows`, `rowKey?`, `onRowClick?`, `highlightRow?`, `empty?`, `loading?`, `stickyHeader` (default true), `maxHeight?`, `dense?`, `footer?` |
| `Dialog` | `open`, `onClose`, `title`, `description`, `footer`, `size` sm\|md\|lg, `dismissible` — renders inside the tablet, Escape closes it first |
| `ConfirmDialog` | `open`, `title`, `message`, `confirmLabel`, `tone` primary\|danger, `reason` (true or `{ label, placeholder, required, maxLength }`), `onConfirm(reason)` (may return a Promise → spinner), `onCancel`, `busy` |
| `Field` | `label`, `hint`, `error`, `required`, `inline` — wires ids/aria for the control inside |
| `TextInput` / `SearchInput` | `value`, `onChange(string)`, `prefix`, `suffix`, `invalid`, `onEnter`, input attrs |
| `NumberInput` | `value (number\|null)`, `onChange`, `min`, `max`, `step`, `integer` (default true), `prefix`, `suffix`, `formatRange` (e.g. formatMoney), `showRange`, `stepper`, `onValidityChange` — shows "Between min and max", refuses out-of-range input (onChange is never called with it) |
| `Select` | `value`, `onChange`, `options [{ value, label, disabled? }]`, `placeholder`, `invalid`, `disabled`, `aria-label`, `className` — a button and a list drawn inside the tablet (not a native `<select>`, whose list CEF draws outside the tablet's scale); arrows, Home/End, Enter/Space and type-ahead; Escape closes the list first. Use it for every dropdown |
| `Textarea` | `value`, `onChange`, `rows`, `maxLength`, `showCount` |
| `Toggle` / `Checkbox` | `checked`, `onChange(bool)`, `label`, `description` (Toggle), `disabled`, `indeterminate` (Checkbox) |
| `ProgressBar` | `value`, `max`, `tone`, `size` sm\|md\|lg, `label`, `showValue` |
| `Stat` | `label`, `value`, `hint`, `icon`, `tone`, `size` |
| `EmptyState` / `ErrorState` / `LoadingBlock` / `Spinner` | `title`, `text`, `icon`, `action`, `compact` / `error`, `onRetry` / `text` / `size` |
| `Countdown` | `seconds`, `paused`, `resetKey`, `warnBelow`, `dangerBelow`, `onDone` |
| `Money` / `MoneyRange` / `Points` | `amount`, `sign` / `range [min, max]` → `$1,040–$1,300` / `value`, `sign`, `suffix` |
| `Icon` | `name` (see `ICON_NAMES`), `size`, `label` |
| `Watermark` / `DeptLogo` | `logo`, `department` — used by the layouts; hide on load error and report `logoFailed` |
| `Toasts`, `ErrorBoundary`, `ScreenStub`, `LayerRootContext` | used by App/layouts |

### 12.7 Browser dev mode

`npm run dev` and open http://localhost:5173. The dev panel (bottom left, browser only) opens the
three UIs, switches department (SAST, FIB, BCSO with a broken logo), sends sample HUD states
(in progress, off route, test run), results (completed, failed, flagged, test), toasts, the fade
overlay, the pinned run bar, and opens a **component gallery** of every shared component.

URL shortcuts: `?ui=officer|supervisor|admin&dept=sast|fib|bcso&screen=<key>&hud=progress|offroute|test`
`&result=completed|failed|flagged|test&run=1&toast=info&gallery=1&bg=night|day|none&dev=0`.

None of it ships into the game path: `main.tsx` imports `src/mocks` and `App` lazy-loads the dev panel
only when `isEnvBrowser()` (no `window.invokeNative`).

---

### 12.8 Officer screens: Mission Board, Active Mission and the shell
Files: `officer/screens/MissionBoard.tsx`, `ActiveMission.tsx`, `types/run_ui.ts`, `mocks/run_ui.mock.ts`,
`locales/parts/run_ui.json`; tests `tests/run_ui_spec.lua` (the screens use exactly these names and shapes).

| Kind | Name | Payload / shape | Screen |
|---|---|---|---|
| request | `getMissionTypes` | `{}` → BoardData (§9.4) | Mission Board |
| push topics | `board`, `operation`, `run` | one coalesced refetch (`run` only when the active run starts or ends) | Mission Board |
| action | `server:acceptType` | the type key or `'weekly_boss'` → `{ runId }`; then `navigate('active')` | Mission Board |
| action | `server:joinOperation` | `operation.id` → `{ id, joined, max }` | Mission Board |
| request | `getRun` | `{}` → ActiveMissionView \| null (§9.4) | Active Mission |
| push topic | `run` | the view (applied as is) or nil (→ getRun) | Active Mission |
| action | `server:abandon` | `runId` → `{ runId }` | Active Mission |
| client action | `setGps` / `recalcRoute` | `{ runId }` → `{ runId }` / `{ recalcsLeft }` | Active Mission |
| client action | `setObjectiveGps` | `{ runId }` → `{ label }` (In progress, no route card, `view.objectiveGps` on, no Radio Silence 'area'/'none') | Active Mission |
| client action | `logResult` | `{ point, choice }` → `true` | Active Mission (Business Check log) |

Mission Board:
- Only types are picked: one card per `BoardData.cards` entry (label, points, cash per officer as a range, pool
  count, Solo / Unit · N, Type of the Day tag with its multiplier, `todMultiplier` else 2); never individual missions,
  except the Weekly Boss card and the Cross-Department card. While `operation` is set only its card shows.
- `locked.reason` arrives translated; `locked.until` is an `os.time()` stamp converted with a server-clock offset
  (`serverTime`, else the offset from the last `open`/`session` message); at 0 the board refetches.
- Card status priority: locked → on a call → server busy → a board-wide blocker (on a mission, not the leader) →
  ready; Accept is disabled for any of these and for an empty pool (the server re-checks). The accept confirm says
  the mission is drawn at random with no reroll and that abandoning, leaving the route or missing the start timeout
  puts the type on cooldown (the boss: uses the week's attempt).
- No success toast for accept (the engine sends `run.accepted`); join shows `board.op.joined_toast`.
- Operation card: status, joined / max with min, the join countdown, Join, "Open Active Mission" once on its run; a
  `joining` operation without `joinEndsIn` shows "Starting".
- Refetch: pushes schedule one refetch 150 ms later; one refused with `err.rate_limited` is retried after 1.2 s; plus
  every 30 s.

Active Mission:
- Abandon (danger confirm) → `server:abandon`; on ok the empty state shows at once (a getRun in flight cannot bring
  the old view back). The text names the cooldown, the boss attempt or the test run, and that partners go on.
- Hero: mission, state badge, `TierBadge` (expected until In progress), "Pay: <tier>" only when lower, modifier and
  boss/operation chips; the timer counts `remaining` locally (restarted from every view; before In progress the
  start timeout from `startIn`, else "–:––").
- Route card while Accepted or the route is on/off (and on a test run with the route off until arrival): status,
  distance, the off-route countdown, Set GPS, Recalculate (confirmed; disabled at 0; shows what is left). Route
  toasts come from modules/route.
- Objectives with number, Current tag, `value/max` bar and `detail`; muted while Accepted
  (`run.objectives.pending`). Partners with status (Left / At the start / En route); the viewer is `view.me`.
- Radio Silence: a note; the screen never shows coordinates or distances to NPCs, only `area` when sent.
- Business Check log: one button per choice → `logResult`; "Logged" until the log point changes, the buttons come
  back if the same point is still asked 6 s later.
- A TEST RUN banner for test runs. A pushed view is applied as is (no getRun per push; getRun allows 6/s); nil
  triggers a getRun; a 15 s safety poll.
- Live cases show their case card; the Contact panel (§5.30) replaces the log when `view.contact` has entries;
  `view.intel` and the mission-call line show when sent.

Shell (layouts):
- `TabletFrame.tsx`: `mergeAppearance` applies the appearance (department, midnight, high_contrast, colourblind) and a
  personal accent that is one of the department's (primary colour, logo and watermark stay the department's); the size
  is `Prefs.uiScale` clamped to `Config.Profile.uiScale` and the viewport (`clampUiScale`, `tabletScale`).
- `Header.tsx`: the Avatar and "Lv n" next to the callsign; the bell (`NotificationBell.tsx`: the last 20 toasts,
  unseen count), also in the Admin header. `Sidebar.tsx` live dot; `navBadges.ts` `useNavCounts()` (getNavCounts + push
  `nav`, again every 5 minutes) and `navBadge(key, counts)`.
- `OfficerLayout` mounts the ReadyCheckBanner above every screen but Unit and refreshes the session on a `profile`
  push. Both tablet layouts call `setMoneyFormat(session.config.format)` (`format.ts`: `formatMoney` follows
  `Config.Format`, `fmtPlain`, dates through the locale's `_meta.date_locale`, en-GB); `data.ts normalizeSession`
  keeps the session's config values.
- ResultScreen: level bar and level-up, XP pending, the mission-call line, the decision ledger, people and items, each
  only when present (`?result=parity` in browser mode).
- Mocks: `?board=normal|unit|member|locked|busy|oncall|boss|bossused|operation|opjoined|oprunning|opwaiting|opclosed|
  empty|error|edge` (`&oncall=1`), `?runv=none|accepted|offroute|progress|test|log|silence|boss|untracked|edge|live`,
  `?result=live|live_open`, `?uiScale=0.85`, `?look=<appearance>`, `?accent=%23rrggbb` (`edge` answers the way Lua's
  JSON arrives). Accepting in the mock starts a simulated run.
