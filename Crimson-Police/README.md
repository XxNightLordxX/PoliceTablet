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
2. No SQL import is needed. The resource creates and upgrades its own `cp_*` tables on start
   (`sql/migrations/`). Your database user must be allowed to create and alter tables.
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
- Back up your database before every update. When updating, keep `config/`, `logos/` and
  `missions/custom/`.
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

## For developers

- Architecture and module contracts: `docs/ARCHITECTURE.md` in the repository.
- UI: `web/` (React 18 + TypeScript + Vite). `npm install && npm run build` rebuilds `web/dist`,
  which is committed. `npm run dev` runs it in a browser with mock data.
- Custom missions published from the Mission Builder are written to `missions/custom/<id>.lua`.
  Edit one and run `/CrimsonPoliceAdmin reload` to load your change as a new version.
