# Mission Builder protocol (CP.Builder)

The one contract between the Mission Builder server (`modules/builder/server.lua`, slice builder_server),
the builder client (`modules/builder/client.lua`: placement tool, route recording, test drive) and the
builder screens (Supervisor UI → Mission Builder `sup_builder`, Admin UI → Missions `admin_missions`).
TypeScript shapes: `web/src/types/builder_server.ts`. Browser mocks: `web/src/mocks/builder_server.mock.ts`.

Everything the server sends or accepts is plain JSON (msgpack between Lua states). All times the UI
shows are seconds; `serverTime` fields are `os.time()` on the server.

---

## 1. The draft definition (BuilderDefinition)

The builder works on **the mission definition of ARCHITECTURE §3.2 in builder units**. It is stored as
JSON in `cp_custom_missions.draft_definition` (the draft) and `published_definition` (a copy of the
published file, plus the reserved `_file` key, §1.6). The Lua file is only produced on publish.

```jsonc
{
  "id": "custom_dockside_raid",       // set by the server; a payload id is ignored
  "label": "Dockside Raid",           // 1–64 characters
  "description": "A smuggling crew…", // 0–500 characters
  "type": "tactical",                 // REQUIRED, a key of Config.MissionTypes (points + base payout)
  "departments": [],                  // keys of Config.Departments; [] = every department
  "minOfficers": 2, "maxOfficers": 4, // Config.Blocks.details.officers (1–4), min <= max
  "difficulty": 3,                    // Config.Blocks.details.difficulty (1–3 stars)
  "timeLimit": 720,                   // SECONDS, Config.Blocks.details.timeLimit (120–1200 = 2–20 min)
  "startTimeout": 600,                // SECONDS, Config.Blocks.details.startTimeout (300–900)
  "cooldown": 1200,                   // SECONDS, Config.Blocks.details.cooldown (300–3600)
  "vehiclePenalties": false,          // default Config.Blocks.details.vehiclePenalties.default
  "locations": [                      // >= Config.Builder.minLocations, at most 20
    {
      "label": "Dock 1",                                               // 1–64 characters
      "start": { "coords": { "x": 1.0, "y": 2.0, "z": 3.0 }, "radius": 60 }, // radius 20–150 m; with a search_area: its startRadius
      "spawns": [ { "x": 1.0, "y": 2.0, "z": 3.0, "w": 90.0 } ],       // any named key: see §1.2
      "evidence": [ { "x": 1.0, "y": 2.0, "z": 3.0 } ],
      "route": { "points": [ { "x": 0, "y": 0, "z": 0 } ], "stops": [ { "at": 12, "wait": 20 } ] }
    }
  ],
  "objectives": [                     // 1..Config.Builder.maxBlocks, in play order
    { "block": "hostile_waves", "label": "Clear the dock", "minSeconds": 45, "presenceRange": 150,
      "waves": [6, 6], "weapons": ["WEAPON_PISTOL", "WEAPON_SMG"], "accuracy": 30, "armour": 10,
      "surrender": { "belowHealth": 0.25, "chance": 30 } },            // chance in PERCENT
    { "block": "interact_points", "label": "Seize the shipment", "minSeconds": 6, "points": "evidence",
      "progress": { "label": "Seizing crates", "duration": 6 } }       // duration in SECONDS
  ],
  "scaling": ["objectives.1.waves"],  // or { "path": "objectives.1.waves", "max": 12 }; at most 20
  "items": [ { "name": "radio", "count": 1 } ],                       // at most 10, count 1–100
  "bonuses":   [ { "id": "no_participant_downed", "pct": 10 } ],     // standard list only (§1.4)
  "penalties": [ { "id": "wrong_log", "points": -5 } ]
}
```

### 1.1 Units (builder form ↔ Lua file)
- Vectors are `{ x, y, z }` (vec3) or `{ x, y, z, w }` (vec4, `w` = heading in degrees). The server
  rounds every component to **2 decimals** when it stores a draft (1 cm), so the file round-trips exactly.
  In the file they are written as `vec3(x, y, z)` / `vec4(x, y, z, w)`.
- Seconds, metres, km/h everywhere, as in mission files, **except** the two conversions below, which
  happen only when the Lua file is written (and are reversed when a file is read back):
  - **Chances are whole percent (0–100)** in the builder, **fractions with two decimals** in the file
    (30 → `0.30`). Fields (builder config `percentFields`):
    `hostile_waves`: `surrender.chance`, `boss.surrender.chance` ·
    `flee_arrest`: `responses.surrender`, `responses.flee`, `responses.fight` (must add up to 100), `armedShare` ·
    `pursuit`: `footFlee` · `interact_points`: `roll.outcomes.*.chance` (must add up to 100).
    Health shares (`belowHealth`) are not chances: they stay fractions (0.25) in both forms.
  - **Progress times are seconds** in the builder (one decimal allowed), **milliseconds** in the file
    (5 → `5000`). Fields (builder config `secondsFields`):
    `interact_points`: `progress.duration`, `roll.outcomes.*.followUp.duration` ·
    `protect_rescue`: `freeTime` · `flee_arrest`: `knock.duration`, `cuff.duration` ·
    `hostile_waves`: `cuff.duration` · `pursuit`: `arrest.duration` ·
    `search_area`: `clueProgress.duration`, `cuff.duration`.
- Percent values are rounded to whole numbers when stored.

### 1.2 Location keys
`start` is required (`{ coords: vec3, radius }`). Every other key is free-form and named by the
objectives that read it (`"points": "evidence"` means `location.evidence`). Values are a vec3, a vec4,
a list of them, a list of `{ coords, heading?, label? }`, a list of lists of vec3 (flee routes), or a
**road route** `{ points: vec3[], stops?: { at, wait }[], loop?: boolean }`. The block's
`requiredPoints(obj)` lists the keys that must be placed in every location.

**Spawn keys** (NPC/vehicle spawn points; builder config `spawnFields`, the objective field that names
the key): `hostile_waves` `spawns`, `boss.spawn` · `protect_rescue` `npcs` · `flee_arrest` `suspect`,
`associates.spawns`, `spawns` (scatter) · `pursuit` `spawn`, `spawns` · `escort` `ambushPoints` ·
`search_area` `hiding`. They must be >= `Config.Builder.minSpawnFromStart` from the location's start.

### 1.3 Road routes (from route recording)
`{ points = { vec3, ... }, stops = { { at = <waypoint index>, wait = <s> } }, loop = true|nil }` — road
waypoints only (snapped to road nodes). Checks: length (sum of waypoint distances) between
`Config.Builder.route.minLength` and `maxLength` (0.8–8 km); open route: first and last waypoint >=
`minStartEndGap` (300 m) apart; `loop = true`: last waypoint within `loopClose` (50 m) of the first; no
waypoint in a no-build zone; 2–500 waypoints; `stops`: at most `Config.Blocks.escort.stops[2]`,
`at` in 1..#points, `wait` within `Config.Blocks.escort.stopWait`. A road path between consecutive
waypoints (`CalculateTravelDistanceBetweenPoints`) is checked by the client while recording (the server
has no path finding).

### 1.4 Bonuses and penalties
Only ids of `Config.Bonuses`. `bonuses` takes ids with a positive value, `penalties` ids with a negative
value. An entry is `{ id, points }` for `kind = 'points'` (flat; penalties negative) or `{ id, pct }` for
`kind = 'pct'` (whole percent of P). A missing value is filled with the config value when the draft is
stored. Caps: `|points| <= Config.Builder.bonusCap.points` (50), `pct <= bonusCap.share × 100` (25).
An id whose config has `block = '<id>'` needs an objective of that block. `each` comes from the config.
File form: `{ id = 'x', points = 5, each = true }` / `{ id = 'x', pctOfPoints = 0.10 }`.

### 1.5 Never in a definition
No payout field (any key containing `payout`, or `cash`, `cashBase`, `basePay`, `money`, `pay`,
`reward`, `rewards`): refused by validate (`builder.error.payout_field`) and stripped when stored.
Loader fields (`source`, `version`, `filePath`, `defHash`, `editedInCode`, `isBoss`, `status`) and the
reserved `_file` key are stripped. Item names `armour`, `bandage`, `ammo-*`, `WEAPON_*` / `weapon_*`
(any case) are refused (CRIMSON_ARENA rule 4).

### 1.6 `published_definition._file`
`{ hash, version, publishedAt, publishedBy, publisher, reason }`: `hash` = `CP.U.hashHex` of the file
content as written (hand edits are detected by comparing it with the file on disk), `publisher` = the
text of the header line ("Sergeant John Doe (SAST, citizenid ABC12345)"), `reason` = `publish` |
`rollback` | `code_edit` | `restore_file`.

---

## 2. Lifecycle, versions and locks

- `status` (DB): `draft` (never published) → `published` → `archived` (→ `published` again by restore).
  The list shows the lifecycle **Draft → Tested → Published → Archived**: `tested` = a draft with
  `draft_tested = 1`. A published mission can carry a draft (`hasDraft`): the next version, edited while
  the published version stays live.
- Versions: a new mission's draft is version 1. The first save of a published mission without a draft
  creates the draft `published_version + 1`. Publish makes the draft the published version and clears
  the draft. Rollback and an accepted hand edit publish `published_version + 1` and move an existing
  draft to the next number. Every run row stores the version it was played on.
- `draft_tested` becomes 1 only through `CP.Builder.onDraftTested` for a passed test of the **current**
  draft (same version and same content as when the test started) at the tier
  `CP.Scaling.tierFor(maxOfficers)` or a higher one. Any stored change of the draft content resets it to 0.
- Edit lock: one editor per mission (`locked_by` citizenid, `locked_until`). `lock`, `save` and
  `autosave` take or renew it for `Config.Builder.editLockMinutes`; it lapses by itself after that. A
  lock held by someone else refuses `save`, `autosave`, `publish`, `test` and `discardDraft` with
  `err.builder_locked`. The lock is released on publish, on `unlock`, when its holder disconnects or
  unloads, and by `breakLock` (admins; supervisors with `breakEditLock`). The UI autosaves every
  `Config.Builder.autosaveSeconds` while it holds the lock.
- Built-in missions are read-only: `builder:get` shows them, `duplicate` copies them.
- A custom mission id is `custom_` + a slug of the label (lower case, `[a-z0-9_]`, at most 40
  characters), unique among custom and built-in missions (`_2`, `_3` … on a clash). While a mission has
  never been published, `save` renames the id when the label's slug changed (the reply carries the new
  `id` and `previousId`).

### Permissions (CP.Permissions.can; admins always pass)
| Action | Own mission (created_by = me) | Someone else's |
|---|---|---|
| builder:list / get / config, create, duplicate | builderEdit | builderEdit |
| lock, unlock, save, autosave, validate, test, discardDraft | builderEdit | builderEditAny |
| publish | builderPublish | builderPublish + builderEditAny |
| archive, restore | builderArchive | builderArchive + builderEditAny |
| rollback | builderRollback | builderRollback + builderEditAny |
| breakLock | breakEditLock | breakEditLock |

Supervisors must be on-duty officers (CP.Access); admins may use the builder off duty. Test runs are
refused with `err.in_arena` while `CP.Alerts.inArena(src)`.

---

## 3. Callbacks (`CP.Net.callback`, reply `{ ok, data, error }`)

### `builder:list` (args `{}`) → `BuilderList`
```ts
{ missions: BuilderListEntry[];   // every cp_custom_missions row (drafts, published, archived), newest change first
  builtins: { id, label, type, source: 'builtin', readOnly: true }[];   // for "duplicate"
  me: string | null;              // my citizenid
  serverTime: number }
BuilderListEntry = {
  id, label, type, source: 'custom',
  status: 'draft' | 'tested' | 'published' | 'archived',    // lifecycle for display
  dbStatus: 'draft' | 'published' | 'archived',
  version: number | null,          // published_version
  draftVersion: number | null, hasDraft: boolean, draftTested: boolean,
  editedInCode: boolean, filePath: string | null,
  owner: { citizenid, name: string | null, mine: boolean },
  updatedBy: { citizenid, name: string | null }, updatedAt: number,     // os.time() seconds
  lock: null | { citizenid, name: string | null, secondsLeft: number, mine: boolean },
  requiredTier: string | null,     // tier name the publish test needs (draft maxOfficers, else published)
  can: { edit, publish, archive, restore, rollback, breakLock, discard: boolean } }
```

### `builder:get` (args `{ id }`) → `BuilderRecord`
`BuilderListEntry` plus
```ts
{ definition: BuilderDefinition;              // the draft, or a copy of the published version (no draft yet)
  publishedDefinition: BuilderDefinition | null;
  readOnly: boolean;                          // built-in, no edit permission, or locked by someone else
  errors: BuilderError[];                     // validation of `definition` right now
  armed: number;                              // armed NPCs before scaling (all blocks, block armedCount)
  backups: number[];                          // versions with a <id>.v<n>.lua.bak (rollback targets), newest first
  publishedAt: number | null; publishedBy: string | null }
```
Built-ins: `source: 'builtin'`, `readOnly: true`, `definition` = the built-in file in builder units,
`status: 'published'`, nulls elsewhere. Errors: `err.builder_unknown_mission`.

### `builder:config` (args `{}`) → `BuilderConfig`
```ts
{ enabled, blocks: Config.Blocks (verbatim, incl. details),
  blockList: { id, labelKey: 'builder.block.<id>', available: boolean /* registered on the server */,
               minSeconds: number /* default */, presenceRange: [min, max, default] }[],
  allowed: Config.Builder.allowed, maxHostiles, maxBlocks, minLocations, maxLocations: 20,
  minLocationGap, minSpawnFromStart,
  bonusCap: { points: 50, pct: 25 },
  bonuses: { id, kind: 'points'|'pct', value /* points, or whole percent */, each, block: string|null,
             penalty: boolean, labelKey: 'bonus.<id>' | 'penalty.<id>' }[],     // Config.Bonuses, sorted
  noBuildZones: { label, coords: Vec3, radius }[],
  departments: { key, label, short }[], missionTypes: { key, label, points }[],
  tiers: { name, labelKey: 'tier.<name>', maxParticipants }[],
  autosaveSeconds, editLockMinutes, testAtMaxTier, keepBackups, exportPath,
  route: Config.Builder.route,
  startRadius: [20, 150, 60], maxItems: 10, itemCount: [1, 100], maxScaling: 20,
  limits: { label: 64, description: 500, objectiveLabel: 64, locationLabel: 64 },
  percentFields: Record<blockId, string[]>, secondsFields: Record<blockId, string[]>,
  spawnFields: Record<blockId, string[]>, forbiddenItems: ['armour', 'bandage', 'ammo-*', 'weapon_*'],
  useStartRoute: Config.Testing.useStartRoute,
  permissions: { builderEdit, builderEditAny, builderPublish, builderArchive, builderRollback, breakEditLock } } // mine; admins all true
```

### BuilderError (in `errors` lists)
`{ path: string, message: string, key?: string, vars?: Record<string, string|number> }` — `path` is a
dotted path into the definition (`label`, `timeLimit`, `locations.2.spawns`, `objectives.1`,
`bonuses.1.points`, `items.2.name`, `scaling.1`); `message` is already translated (show it as is);
`key`/`vars` are the locale key (`builder.error.*`) when the text came from this module (block
`validate` reasons arrive as text only).

---

## 4. Actions (`CP.Net.action('server:builder:<name>')`, reply `{ ok, data | error }`)

Every action returns `err.builder_disabled` when `Config.Builder.enabled` is false, `err.invalid_payload`
for a malformed payload, `err.builder_unknown_mission`, `err.no_permission`, `err.rate_limited`.

| Action | Payload | Result data | Other errors |
|---|---|---|---|
| `server:builder:create` | `{ type, label? }` | `{ id, record: BuilderRecord }` — a draft v1 with one location stub, locked by me | `err.builder_bad_type` |
| `server:builder:duplicate` | `{ id }` (built-in or custom) | `{ id, record }` — editable copy "‹label› (copy)", draft v1, my lock, `record.errors` shows what to fix (built-in values outside builder ranges, non-standard bonuses dropped) | |
| `server:builder:lock` | `{ id }` | `{ id, lock }` | `err.builder_locked`, `err.builder_read_only` |
| `server:builder:unlock` | `{ id }` | `{ id }` | |
| `server:builder:save` | `{ id, definition }` | `{ id, previousId?, version, savedAt, valid, errors: BuilderError[], draftTested, lock }` — always stored (a draft may be incomplete); audited | `err.builder_locked`, `err.builder_too_large` |
| `server:builder:autosave` | `{ id, definition }` | `{ id, version, savedAt, draftTested, lock }` — stored, lock renewed, not audited; at most one per 5 s | `err.builder_locked` |
| `server:builder:validate` | `{ id, definition? }` (stored draft when omitted) | `{ valid, errors, armed, maxHostiles, requiredTier }` | |
| `server:builder:test` | `{ id, tier?, location?, useStartRoute? }` — tier name (default: required tier), location index or `'random'` (default 1), start route (default `Config.Testing.useStartRoute`) | `{ id, version, tier, location, requiredTier }` — `CP.Testing.startDraft(src, def, opts)` with the **stored** draft (autosave first) | `err.in_arena`, `err.builder_bad_tier`, `err.builder_bad_location`, `err.builder_invalid` (not playable), `err.builder_no_draft`, `err.builder_testing_unavailable`, CP.Testing's own keys |
| `server:builder:publish` | `{ id }` | `{ id, version, filePath, backup: string \| null }` | `err.builder_no_draft`, `err.builder_invalid` (call validate for the list), `err.builder_not_tested`, `err.builder_locked`, `err.builder_file_write` |
| `server:builder:archive` | `{ id }` | `{ id, filePath }` | `err.builder_not_published`, `err.builder_file_write` |
| `server:builder:restore` | `{ id }` | `{ id, filePath }` | `err.builder_not_archived`, `err.builder_file_write` |
| `server:builder:rollback` | `{ id }` | `{ id, version, fromVersion }` | `err.builder_not_published`, `err.builder_no_backup`, `err.builder_invalid` |
| `server:builder:breakLock` | `{ id }` | `{ id, previous: { citizenid, name } \| null }` | |
| `server:builder:discardDraft` | `{ id }` | `{ id, deleted }` — a never-published mission is deleted, otherwise only its draft | `err.builder_no_draft`, `err.builder_locked` |

Publish writes `missions/custom/<id>.lua` (SaveResourceFile) in exactly the shape of the spec's custom
example, keeps the previous file as `<id>.v<previous version>.lua.bak` (`Config.Builder.keepBackups`),
stores `published_definition`, releases the lock and calls `CP.Missions.register(def)` (joins its type's
pool at once). Archive moves the file to `missions/custom/archived/<id>.lua` and calls
`CP.Missions.unregister(id)`; restore moves it back and registers it. Rollback reads the newest
`<id>.v<n>.lua.bak` with n < published version, checks it against the guardrails and publishes it as
a new version (the current file becomes a `.bak` in turn).

Live updates: NUI push topic `builder` with `{ event, id, by? }`, `event` = `changed` | `published` |
`archived` | `restored` | `rolledBack` | `tested` | `lockBroken` | `reloaded` | `deleted` (to everyone
who opened the builder in the last 15 minutes). Client Lua event `crimson-police:client:builder`
`{ event = 'lockBroken' | 'reloaded' | 'deleted', id }` goes to the editor who lost the draft or lock,
so the client can stop an active placement/recording for that mission.

---

## 5. Server hooks (Lua)
- `CP.Builder.loadPublished() -> { def, ... }` (for `CP.Missions.loadAll`): every `status = 'published'`
  row → its file (`LoadResourceFile`, parsed in the loader sandbox); definitions carry the loader fields
  (`source = 'custom'`, `version`, `filePath`, `defHash` = file hash, `editedInCode`, `status`). A
  missing file is rewritten from `published_definition` with a warning. A file changed since the last
  publish goes through the hand-edit check first (below).
- `CP.Builder.onReload() -> summary` (from `CP.Missions.reload`): for every published mission, file hash
  vs `_file.hash`: unchanged → nothing; changed → parse, strip payout fields (console warning), check the
  same guardrails (the test requirement excepted) → new version marked `edited_in_code` (header version
  line updated), previous published version kept as `.v<n>.lua.bak`; if the builder draft also changed
  since the last publish the file wins, the draft goes to `<id>.draft.lua.bak`, the draft is cleared and
  the conflict is audited. A file that fails the guardrails is kept on disk but not used (the last
  published version stays live) and the reason is printed. Summary
  `{ checked, unchanged, edited = { { id, version } }, rejected = { { id, error } }, conflicts = { id },
  rewritten = { id } }`.
- `CP.Builder.onDraftTested(missionId, version, tierName, passed, src) -> boolean` (from `CP.Testing`).
- `CP.Builder.validate(def, opts) -> errors` and `CP.Builder.exportLua(def, meta) -> text` (pure; tests).

---

## 6. Client protocol (builder client ↔ builder UI)

The placement tool, recording and test drive take minutes, longer than an NUI request may wait (20 s),
so each is **started** by a client action and its **result is delivered later**.

Client actions (registered by `modules/builder/client.lua` with `CP.Tablet.registerClientAction`):

| name | payload | immediate reply |
|---|---|---|
| `builderPlace` | `{ missionId, location, key, kind: 'ped'\|'vehicle'\|'marker'\|'area'\|'start', model?, heading: boolean, multiple: boolean, min?, max?, radius?, points: (Vec3\|Vec4)[], start: Vec3\|null, spawn: boolean, otherStarts: Vec3[] }` | `{ started: true }` or `err.in_arena` / `err.builder_busy` |
| `builderRecord` | `{ missionId, location, key, stops: boolean, loop: boolean }` | `{ started: true }` |
| `builderTestDrive` | `{ missionId, location, key, route: BuilderRoute, vehicle, speed, style }` | `{ started: true }` |
| `builderResult` | `{}` | the pending result below (or `null`), and clears it |
| `builderCancel` | `{}` | `{ cancelled: boolean }` |
| `builderWaypoint` | `{ coords: Vec3 }` | `{ ok: true }` (GPS waypoint to a spot; the builder never teleports players) |

The tablet closes while the tool runs and reopens on the builder screen when it ends. The result is
kept on the client until read and also pushed to the NUI (topic `builder`, `event = 'clientResult'`):

```ts
BuilderClientResult =
 | { kind: 'placement'; missionId; location; key; points: (Vec3|Vec4)[]; radius?: number; cancelled: boolean }
 | { kind: 'recording'; missionId; location; key; cancelled: boolean;
     route: { points: Vec3[]; stops: { at: number; wait: number }[]; loop?: boolean };
     length: number;              // metres
     rejected: number;            // samples dropped as "Off road" (> Config.Builder.route.maxOffRoad from a road node)
     rejectedSamples: Vec3[];     // where (at most 50), for the map
     unreachable: number[] }      // waypoint indexes with no road path to the next one
 | { kind: 'testdrive'; missionId; location; key; completed: boolean; failed: number[] /* waypoints not reached within testDriveTimeout */; cancelled: boolean }
```
For `kind: 'start'`, `points` holds one vec3 and `radius` the start radius. The UI writes points into
`definition.locations[location - 1][key]` (a single vec for single-point keys, a list otherwise) and
autosaves. Placement checks on the client (a failing spot shows red and cannot be placed): on the ground
(not in water, inside walls or in the air), outside `noBuildZones` (2D), spawn keys >= `minSpawnFromStart`
from `start`, a start >= `minLocationGap` from `otherStarts`. The server re-checks z sanity, no-build
zones, the start distance and the location gap on save/publish.

Overlays (`CP.Tablet.overlay`): `{ kind: 'placement', key, placed, min, max, valid, reason? }`,
`{ kind: 'recording', key, length, points, stops, paused, offRoad, rejected }`,
`{ kind: 'testdrive', waypoint, total, failed }`, `nil` to hide.
