# Crimson-Police

A standalone police tablet for **Qbox** servers. On-duty officers pick a mission type (Patrol,
Training, Investigation or Tactical), the server draws a random NPC mission scaled to their team, and
completed runs pay cash through Renewed-Banking and earn leaderboard points. Supervisors get
oversight tools and a Mission Builder; admins get a full-screen admin panel.

- Officer UI: `/CrimsonPolice`, the `crimsonpolice_tablet` key mapping, the optional tablet item or a mission desk
- Admin UI and console commands: `/CrimsonPoliceAdmin`

What this build adds (the parity-plus release; the rules are in `docs/SPEC.md`):

- **Dispatch**: tablet-only NPC mission calls (type, priority, area; the mission is still drawn at random after
  the claim), first unit to claim wins, rapid-response points, re-dispatch, supervisor page/withdraw/create. They
  never touch SC-Dispatch, and real calls always come first.
- **Police actions and decisions**: traffic stops, parked cars and scene contacts with a hidden truth found through
  real actions (talk, frisk, search with probable cause, run plate ...), graded dispositions, a custody chain to an
  NPC prisoner van, a Crimson-Police tow truck for impounds, and Process the scene with a coroner van.
- **Five new missions** (18 plus the Weekly Boss): Illegal Parking Patrol, Traffic Enforcement, Suspicious
  Activity, Drug Lab Raid and Gang Hideout Raid.
- **Progression**: a 50-level XP curve (the XP level names are its bands), a service record, "Rank by" boards
  (arrests, impounds, citations, rescues, mission calls, judgement), commendations, profile pictures and bios with
  moderation, personal accents and accessibility looks.
- **Teams**: kick, make leader, disband, withdraw an invite, a ready check before every unit draw, operation
  leave and waitlist.
- **Tablet**: mission desks, an optional "require the item" mode, sidebar badges, a notification bell and a
  Config health panel.
- **Item rewards**: optional ox_inventory rewards, **off by default** (`Config.Rewards.enabled = false`).
- English only: `locales/en.json` is the only language file.

## Requirements

Qbox only. Start these **before** Crimson-Police:

```
ensure oxmysql
ensure ox_lib
ensure qbx_core
ensure ox_target
ensure ox_inventory
ensure Renewed-Banking
ensure sc-police
ensure sc-dispatch
ensure sc-ambulance
ensure sc-multijob
ensure sc-npcpolice
ensure Crimson-Police
```

OneSync must be enabled (mission NPCs are created by the server). The resource folder **must** be
named `Crimson-Police`.

## Install

1. Copy the `Crimson-Police` folder into your resources.
2. You never import any SQL, on a new install or on an update. With the database on (the default)
   Crimson-Police creates and upgrades its own `cp_*` tables on start (`sql/migrations/`); your
   database user must be allowed to create and alter tables. To run without a database, see
   [Database off](#database-off) below.
3. Give admins the ace in `server.cfg`:
   ```
   add_ace group.admin crimsonpolice.admin allow
   ```
4. Optional Discord webhooks, as convars in `server.cfg` (leave out any you don't want):
   ```
   set cp_webhook_board      "https://discord.com/api/webhooks/..."   # weekly top 3, season results
   set cp_webhook_audit      "https://discord.com/api/webhooks/..."   # payout changes, admin actions
   set cp_webhook_flags      "https://discord.com/api/webhooks/..."   # flagged runs, voids, disputes
   set cp_webhook_builder    "https://discord.com/api/webhooks/..."   # publish, archive, rollback, tests
   set cp_webhook_operations "https://discord.com/api/webhooks/..."   # Cross-Department Missions
   ```
5. Put each department's logo in `logos/` (the shipped `sast.png` and `fib.png` are placeholders).
6. Optional tablet item: follow `items/README.md` (paste `items/ox_inventory_items.lua` into
   `ox_inventory/data/items.lua`, copy `items/crimson_police_tablet.png` into `ox_inventory/web/images/`, then set
   `Config.Tablet.item = 'crimson_police_tablet'`). `Config.Tablet.access.requireItem = true` makes every way
   except a mission desk need the item.
7. Mission desks: two placeholder desks ship in `Config.Tablet.desks` (Mission Row PD front desk, Sandy Shores
   office). Check their coordinates against your station MLOs, or set `Config.Tablet.access.desk = false`.

## Database off

Set `enabled = false` in the `Config.Database` block of `config/config.lua` and Crimson-Police keeps all
of its data without MySQL/MariaDB. Every feature works exactly the same: runs, points and XP, cash payouts,
leaderboards, seasons, payout settings, disputes, suspensions, the audit log and custom missions.

A `config.lua` kept from a version before this option has no `Config.Database` block (a single
`Config.Database.enabled = false` line then stops `config.lua` with an error and the database stays on).
Add the whole block:

```lua
Config.Database = {
  enabled = false,
  folder  = 'saves',
}
```

- Everything is saved in `Crimson-Police/saves/`: small JSON documents, one per table (a big table
  is split into documents of 500 rows), plus `_tables.json`, which describes them. Each change is
  written to its document straight away; nothing else is stored. `Config.Database.folder` can name
  another folder inside the Crimson-Police folder. FXServer only lets a resource write inside resource
  folders, so a folder elsewhere on the machine does not work (the console says so on start).
- Keep the `saves` folder when you update the resource, and back it up like you would a database.
  Don't edit the files while the server is running. You can open and read them; if you edit one with
  the server stopped, it must stay valid JSON (any editor or formatter is fine). A document that no
  longer reads correctly stops Crimson-Police on start with its name and line, and nothing in the
  folder is changed.
- Don't delete documents to save space: a missing document is reported in the console on start, and
  its rows are gone until you put it back from a backup.
- Keep oxmysql started: it is still a dependency, and Crimson-Police reads SC-Dispatch's calls
  through it. With the database off, Crimson-Police creates no tables and saves nothing in your
  database, unless you copy data there (see below).
- The console names the storage on start (`[crimson-police] storage: ...`).
  `/CrimsonPoliceAdmin storage` shows the storage in use, the rows of every table and the size of
  the saves folder.

**Switching an existing server.** Changing `enabled` moves no data by itself: Crimson-Police starts with
what the other storage holds, which is nothing the first time (the console warns about it). That
includes cash payouts still waiting for an officer to come online and the records of custom missions
(their versions and published state; the Lua files in `missions/custom/` stay where they are). Back up
both, copy the data, then switch and restart:

- Database to saves folder: `/CrimsonPoliceAdmin storage copy database-to-files`, then set
  `Config.Database.enabled = false` and restart Crimson-Police.
- Saves folder to database: `/CrimsonPoliceAdmin storage copy files-to-database` (missing tables are
  created in the database first), then set `Config.Database.enabled = true` and restart Crimson-Police.

Run the copy from the server console, or in game with the `crimsonpolice.admin` ace. It copies every
Crimson-Police table and keeps every id. It refuses to start while a mission run is active, and it
refuses a target that already has data unless you add `force`, which replaces that data. If a copy
fails, the target is left empty and the source is untouched, so you can fix the problem and run it
again. The copy is written to the audit log. You can also switch first and copy afterwards. In that
case, restart Crimson-Police once more after the copy.

**Which to use.** The saves folder is fine for normal servers. It was tested with 50,000 runs: every
board and admin screen answered in under a quarter of a second, start-up read the folder in about
1.5 s, the loaded tables took about 75 MB of the server's memory, and the folder took about 42 MB.
Archived runs (`cp_mission_runs_archive`) stay in memory too, because the all-time board and badges
read them. For a very large history (hundreds of thousands of runs, or retention switched off for
years), use a database: the saves folder keeps every table in the server's memory (about 1.2 KB per
run) and reads the whole folder on every start (about 1.5 s per 50,000 runs).

## Server owner checklist

- Set each department's `supervisorGrade` in `config/config.lua` to your real Qbox grade level.
  sc-police's grade comments put Corporal at 3 and Sergeant at 4; SC-Dispatch treats grade 4+ as
  command staff.
- Replace the placeholder payouts in `Config.MissionTypes` and `Config.Events.weeklyBoss`.
- Make sure your qbx_core `shared/jobs.lua` defines the department jobs (`sast`, `fib`, …). The
  stock Qbox job list has no `sast` or `fib`.
- Keep `Config.Integrations.CrimsonArena = true` in SC-Dispatch and
  `Config.ArenaIntegration.Enabled = true` in SC-Ambulance: mission alert suppression depends on both.
- Keep `Config.DispatcherMode.AutoResponding` on in SC-Dispatch, so dispatcher assignments end runs.
- Every department job must be in SC-Dispatch's `Config.Police.AllowedJobs`.
- Check that the Bolingbroke entry in `Config.Builder.noBuildZones` covers your prison interior.
- SC-Dispatch only exempts on-duty `police`, `bcso` and `fib` from shots-fired calls outside
  missions. Adding `sast` is an edit you make in SC-Dispatch yourself; Crimson-Police never edits it.
- Set the server machine's time zone; daily/weekly resets and the Weekly Boss days use server time.
- Back up your database (or, with the database off, the `saves` folder) before every update. When
  updating, keep `config/`, `logos/`, `missions/custom/` and `saves/`.
- Crimson-Arena can run alongside: see `docs/CRIMSON_ARENA.md` in the repository.

Parity-plus build:

- Read the amendments in `docs/SPEC.md` (Hard rules → Mission choice, Do not build → Missions, the Officer UI's
  eighth screen Dispatch, bodies kept for Process the scene) and confirm them before go-live.
- Test every new location at Heavy tier in **Admin UI → Testing** before go-live (see Before go-live).
- Check the mission desk coordinates against your MLOs, or turn desks off (`Config.Tablet.access.desk`).
- Item rewards ship off (`Config.Rewards.enabled = false`). To use them, set `enabled = true` and either switch on
  the example pools (`useExamplePools = true`: water, burger and sprunk) or fill `Config.Rewards` with items that
  exist in your ox_inventory and suit your economy. Admin UI → Permissions → Config health shows what is on and
  whether every item exists.
- Profile pictures from links are off by default; if you turn them on, set `Config.Profile.avatarUrls.hosts` to
  hosts you trust (Imgur is blocked in the UK and some other regions; Discord links expire). Review
  `config/banned_words.txt` for your community.
- Tell officers never to use sc-police's `/imp` or `/depot` on mission vehicles: they use the tablet's Impound.
  A participant's `/imp` fails the objective and flags the run; one by anyone else ends the run as not counted.
- Optional clean-up: `tests/zone_lint_baseline.txt` (in the repository) lists built-in locations of different
  missions closer than 200 m. They never run at the same time (the draw's zone clearance), so nothing is
  required; moving one later needs a retest.
- Known SC-Dispatch behaviour: when a dispatcher detaches an officer from a real call within 60 s of marking
  them, sc-dispatch un-marks them and Crimson-Police counts a normal abandon (the 5-minute type cooldown). Ask
  dispatchers to avoid Detach in the first minute.
- Database off: the four new tables (mission calls, commendations, profile reports, item rewards) live in the
  saves folder with the rest; back it up before updating, and `/CrimsonPoliceAdmin storage copy` moves them too.

## Adding a department

Copy the `fib` block in `Config.Departments`, rename the key (e.g. `bcso`), set label, short, jobs,
supervisorGrade, societyAccount, theme and logo, put `bcso.png` in `logos/`, restart. No code or SQL
changes.

## Before go-live

Every built-in mission location and route was placed from GTA V map data and checked by tests, but
has not been driven in game. Run each mission once from **Admin UI → Testing** (any location, any
tier, nothing is saved or paid) and mark it Passed or Failed. The screen shows what still needs
checking.

## Spec revisions

`docs/SPEC.md` was revised to match these owner-approved changes:

- Driving a vehicle instead of a police vehicle: Beat Patrol, EVOC Course and checkpoint routes with
  **Vehicle required** on count a checkpoint while the officer drives any vehicle (checked on the server).
- Extra builder peds: `Config.Builder.allowed.peds` includes the inmate, Kingpin and escort-driver models.
- Search-mission start radius: with a search area objective, every start radius equals its search circle (200–1000 m).
- Crimson-Arena no-build zones: the Trailer Park and the lobby are in `Config.Builder.noBuildZones`.
- Parity-plus (this build): mission calls may be claimed on the Dispatch screen (the mission is still drawn at
  random after the claim); Traffic Enforcement, Illegal Parking Patrol and Suspicious Activity are allowed; the
  Officer UI has eight screens; bodies may be kept for a Process the scene objective. English only; item rewards
  ship off.

## For developers

- Architecture and module contracts: `docs/ARCHITECTURE.md` in the repository.
- UI: `web/` (React 18 + TypeScript + Vite). `npm install && npm run build` rebuilds `web/dist`,
  which is committed. `npm run dev` runs it in a browser with mock data.
- Custom missions published from the Mission Builder are written to `missions/custom/<id>.lua`.
  Edit one and run `/CrimsonPoliceAdmin reload` to load your change as a new version.
