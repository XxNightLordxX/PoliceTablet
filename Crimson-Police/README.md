# Crimson-Police

A standalone police tablet for **Qbox** servers. On-duty officers pick a mission type (Patrol,
Training, Investigation or Tactical), the server draws a random NPC mission scaled to their team, and
completed runs pay cash through Renewed-Banking and earn leaderboard points. Supervisors get
oversight tools and a Mission Builder; admins get a full-screen admin panel.

- Officer UI: `/CrimsonPolice` (optional keybind or tablet item)
- Admin UI and console commands: `/CrimsonPoliceAdmin`

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
6. Optional tablet item: set `Config.Tablet.item = 'crimson_police_tablet'` and add to
   `ox_inventory/data/items.lua`:
   ```lua
   ['crimson_police_tablet'] = {
       label = 'Police Tablet', weight = 500, stack = false, close = true,
       client = { export = 'Crimson-Police.useTablet' },
   },
   ```

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

## For developers

- Architecture and module contracts: `docs/ARCHITECTURE.md` in the repository.
- UI: `web/` (React 18 + TypeScript + Vite). `npm install && npm run build` rebuilds `web/dist`,
  which is committed. `npm run dev` runs it in a browser with mock data.
- Custom missions published from the Mission Builder are written to `missions/custom/<id>.lua`.
  Edit one and run `/CrimsonPoliceAdmin reload` to load your change as a new version.
