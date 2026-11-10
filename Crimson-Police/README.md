# Crimson-Police

The owner's guide is the `README.md` one folder up, in the repository root (the front page on GitHub), with every
detail in `docs/OWNER_GUIDE.md`. Start at
[3. Install in 5 minutes](../README.md#3-install-in-5-minutes). This note is the short version, for when you only
have this folder.

Crimson-Police is a police tablet for **Qbox** servers: on-duty officers pick a mission type, the server draws a
random NPC mission, and finished missions pay cash and earn leaderboard points.

## Install

1. Put this folder in your server's `resources` folder (a category folder like `resources/[police]/` is fine),
   named exactly `Crimson-Police`. The file `resources/Crimson-Police/fxmanifest.lua` must exist.
2. Add to the bottom of `server.cfg`:
   ```cfg
   ensure Crimson-Police
   add_ace group.admin crimsonpolice.admin allow
   ```
   The first line starts it. The second lets your server admins open the Admin UI (Qbox admins already can while
   `Config.QboxAdmins = true` in `config/config.lua`). To add more admins, or a Crimson-Police-only admin, see
   [4. Admins, supervisors and permissions](../README.md#4-admins-supervisors-and-permissions). Optional Discord
   webhooks are `set cp_webhook_<name> "..."` lines: see
   [guide 3.6 Discord webhooks](../docs/OWNER_GUIDE.md#36-discord-webhooks).
3. Check that your Qbox jobs match `jobs` in `Config.Departments` (`config/config.lua`). The shipped departments
   use the jobs `sast` and `fib`, which a stock Qbox server does not have: add them to Qbox, or put your own job
   name in `jobs`. Set `supervisorGrade` to the Qbox grade number where supervisors start.
4. Start the server. About 5 seconds after Crimson-Police starts, the console prints its start-up check. Fix any
   yellow or red line it prints (each one says how), then restart Crimson-Police. Type `CrimsonPoliceAdmin check`
   in the server console to see every line again.
5. In game: officers on duty type `/CrimsonPolice`; admins type `/CrimsonPoliceAdmin`. **Esc** closes either one.

You never have to edit `config/config.lua`: an admin can change every setting in game in `/CrimsonPoliceAdmin` →
**Settings**, and switch missions and their locations on or off in **Missions** (see
[guide 2.6](../docs/OWNER_GUIDE.md#26-change-any-setting-in-game-the-settings-screen)). Testing missions is optional. Admins also
edit any mission (built-in ones too), correct officers' records, handle payments, add departments and make backups
there: the list is in [README 4.4](../README.md#44-things-only-admins-can-do). Who is an admin, Discord webhook links and
restarting Crimson-Police stay in server.cfg and txAdmin.

Mission NPCs carry pistols and pump shotguns only (never automatic weapons), aim worse, fire single shots and do half
damage, and officers on a run take no headshot one-shots. Make them easier or harder with `Config.NpcCombat` (lower =
easier): see [guide 2.8 How hard NPCs fight back](../docs/OWNER_GUIDE.md#28-how-hard-npcs-fight-back).

Required resources (they start before Crimson-Police by themselves): `oxmysql`, `ox_lib`, `qbx_core`, `ox_target`
and `ox_inventory`. There is no SQL to import. Dispatch, ambulance, banking and police scripts are optional:
`Config.Integrations` finds them ([Supported scripts](../README.md#21-supported-scripts)).

Two switches at the top of `config/config.lua`, as shipped:

- `Config.Debug = true`: debug is on for testing, so the console shows many extra lines. Before go-live, set it
  to `false` and restart Crimson-Police.
- `Config.Database.enabled = false`: the database is off, so all data is saved as files in the `saves/` folder.
  Nothing to set up. To use your MySQL/MariaDB database instead, set it to `true` and restart Crimson-Police: it
  makes its own tables through oxmysql (the same `set mysql_connection_string` line Qbox already uses). If the
  server already has data, copy it first: see
  [README 5.1 The two switches at the top](../README.md#51-the-two-switches-at-the-top-debug-and-storage).

## What is in this folder

| Folder or file | What it is | Keep it when you update? |
|---|---|---|
| `config/` | Every setting: `config.lua`, `blocks.lua` (Mission Builder ranges), `banned_words.txt`; `examples/generic.lua` is a starting config for a fresh Qbox city (copy it over `config.lua`) | **Yes** (take the new `blocks.lua` unless you changed it) |
| `logos/` | One logo per department (see `logos/README.md`) | **Yes** |
| `missions/custom/` | Missions made with the Mission Builder, and your edited built-in missions in `overrides/`. They are data files the server reads and never runs: a hand edit keeps the Builder's layout ([guide 5.12](../docs/OWNER_GUIDE.md#512-mission-builder)) | **Yes** (all of it) |
| `saves/` | Your data while the database is off, and the in-game backups in `saves/_backups/` (see `saves/README.md`) | **Yes** |
| `items/` | The optional tablet item to copy into ox_inventory (see `items/README.md`) | Replace |
| `missions/builtin/` | The built-in missions | Replace |
| `web/` | The tablet's screens, ready-built in `web/dist` (see `web/README.md`) | Replace |
| `fxmanifest.lua`, `shared/`, `modules/`, `blocks/`, `locales/`, `sql/` | The resource itself | Replace |
| `CHANGELOG.md`, `LICENSE` | What changed in each version; the license (the owner fills it in) | Replace |


Back up your database (or the `saves` folder with the database off) before every update. The steps are in
[guide 7.2 Updating](../docs/OWNER_GUIDE.md#72-updating).

## First-start setup

With `Config.AdminUi.setupScreen = true` (the generic config ships it on; this server's `config.lua` ships it off,
so Home opens on its dashboard as before) Admin UI → **Home** shows the **First-start setup** to admins until one
presses **Finish** or **Skip setup**. Its five steps:

1. **Departments and supervisor grades**: which Qbox jobs belong to each department (the police jobs qbx_core has,
   type `leo`), from which grade they supervise, and a new department for each police job none lists.
2. **Mission desks**: untick a desk your city does not use (the shipped desks stand at the Qbox police stations).
3. **Storage**: where data is saved now. That choice stays in `config.lua` (`Config.Database.enabled`); the copy
   command takes data along.
4. **Other scripts**: the dispatch, ambulance, banking and police scripts found, and the choice for each
   (`Config.Integrations`).
5. **Preset**: none, Casual, Serious RP or Go-live (`Config.AdminUi.presets`).

Every answer is saved as a normal setting (in the settings history and the Activity log, with "First-start setup"
as the reason), so you change any of it later in **Settings** or **Departments**. Finishing or skipping sets
`Config.AdminUi.setupDone = true`; set it back to `false` to walk through it again.

## Packaging a copy for sale, and what you can edit

- **Install in 5 minutes on a fresh Qbox city:** the steps under Install above, starting from the generic config.
- **The generic config.** `config/examples/generic.lua` is a starting config for any Qbox city: departments from
  qbx_core's own police jobs (`police`, `bcso`, `sasp`, supervisors from grade 3 Lieutenant), every dispatch,
  ambulance, banking and police script on `auto`, no zone of a private script, and the First-start setup on.
  **To package a copy for sale, copy `config/examples/generic.lua` over `config/config.lua`.** This server's own
  `config.lua` stays as it is.
- **What a city edits (left out of FiveM asset escrow by `escrow_ignore` in `fxmanifest.lua`):** `config/` (every
  `.lua` file there and in `config/examples/`), `locales/` (every text), `missions/builtin/` (the built-in missions,
  readable and editable) and `missions/custom/` (the missions made in game). `web/dist` ships built. Everything
  else is the resource's code.
- **Nothing private ships:** no secrets (Discord webhooks are server.cfg convars), no paths of this server, and the
  live crimes of the private contracts script stay off (`Config.RealPlayers.liveCrime.enabled = false`). No
  third-party code is copied in; each coordinate taken from a Qbox script names its source on its line
  (`tests/setup_coords_spec.lua` checks them).
- **License:** `LICENSE` (the owner fills it in before sale). **Changes:** `CHANGELOG.md`.
