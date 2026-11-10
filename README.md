# Crimson-Police

A police tablet for **Qbox** FiveM servers. On-duty officers pick a mission type, the server gives them a random
NPC mission, and finished missions pay cash and earn leaderboard points.

**This page is the owner's guide**: install, admins, what ships off and how to turn it on, commands, a tour of the
Admin UI and troubleshooting. Every other detail is in [docs/OWNER_GUIDE.md](docs/OWNER_GUIDE.md) (the guide), and
every setting is explained by its own comment in `Crimson-Police/config/config.lua`, which Admin UI → **Settings**
shows next to it. The small README files inside the folders (`Crimson-Police/`, `items/`, `logos/`, `saves/`, `web/`)
say the same things in short and point back here.

## Contents

1. [What Crimson-Police is](#1-what-crimson-police-is)
2. [What you need](#2-what-you-need)
3. [Install in 5 minutes](#3-install-in-5-minutes)
   - [3.1 Put the folder in resources](#31-put-the-folder-in-resources)
   - [3.2 Paste this into server.cfg](#32-paste-this-into-servercfg)
   - [3.3 Check your police jobs](#33-check-your-police-jobs)
   - [3.4 Start the server and read the console](#34-start-the-server-and-read-the-console)
   - [3.5 Open the tablet in game](#35-open-the-tablet-in-game)
4. [Admins, supervisors and permissions](#4-admins-supervisors-and-permissions)
   - [4.1 The three roles](#41-the-three-roles)
   - [4.2 Admins](#42-admins)
   - [4.3 Supervisors](#43-supervisors)
   - [4.4 Things only admins can do](#44-things-only-admins-can-do)
   - [4.5 The server console](#45-the-server-console)
   - [4.6 Common mistakes](#46-common-mistakes)
5. [Debug, storage and what ships off](#5-debug-storage-and-what-ships-off)
   - [5.1 The two switches at the top: debug and storage](#51-the-two-switches-at-the-top-debug-and-storage)
   - [5.2 What ships off and how to turn it on](#52-what-ships-off-and-how-to-turn-it-on)
6. [All commands and keys](#6-all-commands-and-keys)
   - [6.1 Commands](#61-commands)
   - [6.2 Keys](#62-keys)
7. [Admin UI tour](#7-admin-ui-tour)
8. [Troubleshooting](#8-troubleshooting)
   - [8.1 The tablet does not open](#81-the-tablet-does-not-open)
   - [8.2 Admin UI](#82-admin-ui)
   - [8.3 Start-up check lines](#83-start-up-check-lines)
   - [8.4 The screen froze or the controls stopped](#84-the-screen-froze-or-the-controls-stopped)
   - [8.5 Restarting ox_inventory while Crimson-Police runs](#85-restarting-ox_inventory-while-crimson-police-runs)
9. [More documents](#9-more-documents)

---

## 1. What Crimson-Police is

Crimson-Police gives on-duty police something to do in quiet moments. An officer opens the tablet, picks a mission
type (Patrol, Training, Investigation or Tactical) and the server draws a random NPC mission of that type. The
mission gets harder with more officers, and pays more. Real calls always come first: when an officer responds to a
real SC-Dispatch call, their mission ends at once with no penalty. Everything runs on the server, so players
cannot cheat points or cash.

What is in it, one line each:

- **Missions**: 18 NPC missions plus a Weekly Boss, from traffic stops to hostage rescues and drug lab raids.
- **Dispatch**: the tablet posts its own NPC mission calls; the first unit to claim one gets a mission in that area.
- **Police actions**: talk, frisk, search, run plates, cite, arrest and impound, graded against what was really going
  on.
- **Custody**: arrested NPCs go to a prisoner van, impounded cars to a tow truck, scenes to a coroner van.
- **Units**: officers from any department team up; bigger units get harder missions and more pay.
- **Cross-Department Missions**: a supervisor launches one big mission for every department at once.
- **Cash payouts**: paid into the officer's bank account (with a Renewed-Banking history line), from new money or
  the department's account.
- **XP and levels**: 50 levels plus prestige stars. They are for show only and never change a player's Qbox rank.
- **Leaderboards**: weekly, monthly, season and all-time, ranked by points, arrests, impounds and more.
- **Department challenge and seasons**: departments compete over a season, with a weekly bounty.
- **Profiles**: pictures, bios, commendations and a service record, with moderation.
- **Admin UI**: every setting, payout and tool in game ([7](#7-admin-ui-tour)); you never have to edit `config.lua`.
- **Mission Builder**: supervisors and admins build new missions in game, with no coding.
- **Test mode**: admins play any mission at any location and size; nothing is saved or paid. Testing is
  optional: nothing needs a test before it is used.
- **Item rewards**: optional ox_inventory items for finished missions. **Off** until you turn them on.
- **No SQL to import**: Crimson-Police makes its own tables, or saves to files with the database off.

English is the only language.

---

## 2. What you need

- **A Qbox server** (qbx_core). QBCore is not supported.
- **OneSync**. Every Qbox server already has it on, so there is nothing to do.
- **These resources, with exactly these folder names.** Crimson-Police will not start without them. You do not
  need to start them in a special order: FXServer starts them before Crimson-Police by itself.

  | Resource | What Crimson-Police uses it for |
  |---|---|
  | `oxmysql` | The database (Qbox already uses it) |
  | `ox_lib` | Progress bars, skill checks and zones during missions |
  | `qbx_core` | Players, jobs, grades, duty and money |
  | `ox_target` | Interacting with mission NPCs, cars and props, and mission desks |
  | `ox_inventory` | Mission items, and the optional tablet item and item rewards |
  | `sc-dispatch` | Knowing when an officer takes a real call, and hiding mission gunfire from dispatch |
  | `sc-ambulance` | EMS on duty, revives, and hiding downed officers from EMS alerts |
  | `Renewed-Banking` | The bank history line for each payout, and optional department accounts |

- **These resources are used when they run**, but Crimson-Police starts without them:

  | Resource | What happens without it |
  |---|---|
  | `sc-police` | Officers can't set a callsign with /callsign, and officers suspended in sc-dispatch are not kept off
  duty. The start-up check warns you |
  | `sc-multijob` | Nothing changes. With it, only a player's **active** job counts |
  | `sc-npcpolice` | Nothing changes. With it, its NPC calls never end a mission |
  | `Crimson-Arena` | Nothing changes. With it, players in the arena can't use the tablet, and both run side by side |

- **A database**: the MariaDB your Qbox server already uses, through oxmysql. Qbox asks for MariaDB 10.9 or newer
  and does not support MySQL; Crimson-Police itself needs MariaDB 10.3 or newer and is tested on 10.11 and 12.3
  (the version Qbox recommends). To see yours, run `SELECT VERSION();` on the database named in
  `set mysql_connection_string` (HeidiSQL, phpMyAdmin or your host's panel). On an older server Crimson-Police does
  not start with the database on, and the console says why and what to do. On MySQL it starts with a warning. A
  database made by txAdmin's recipe uses the older `utf8` character set, which can't hold emoji: on its first start
  with the database on, and in a `storage copy files-to-database`, Crimson-Police switches its own tables to
  `utf8mb4` (one console line per table), so names and reasons with emoji are kept. With the database on,
  your database user must be allowed to create and change tables (if your host asks: the CREATE, ALTER and INDEX
  rights, plus the usual SELECT, INSERT, UPDATE and DELETE). With the database off (as shipped, see
  [5.1](#51-the-two-switches-at-the-top-debug-and-storage)), Crimson-Police saves to files instead and needs
  nothing more.

---

## 3. Install in 5 minutes

### 3.1 Put the folder in resources

1. Download Crimson-Police. A GitHub download is a zip with a folder like `PoliceTablet-main` inside. That folder
   holds `Crimson-Police`, plus `docs`, `tests` and `tools`, which your server does not need.
2. Drag **only the `Crimson-Police` folder** into your server's `resources` folder. A category folder is fine,
   for example `resources/[police]/Crimson-Police`. Copy it whole, with its empty folders (each holds a `.gitkeep`
   file): the server cannot create folders on Linux, so Crimson-Police uses the ones it ships.
3. Check it: the file `resources/Crimson-Police/fxmanifest.lua` must exist (or
   `resources/[police]/Crimson-Police/fxmanifest.lua` in a category folder). If you see
   `Crimson-Police/Crimson-Police/fxmanifest.lua`, you copied one folder too high: move the inner folder up.
4. Keep the folder name exactly `Crimson-Police`, with the capital letters and the dash. (If you rename it, the
   tablet still works, but the tablet item and other scripts must use the new name. The start-up check tells you
   what to change.)

You never import any SQL, on a new install or on an update.

### 3.2 Paste this into server.cfg

Copy this whole block to the bottom of your `server.cfg`. Lines that start with `#` are notes, and the server
skips them. Remove the `#` at the start of a line to switch that line on.

```cfg
# ============ Crimson-Police ============

# Start Crimson-Police. Keep this line after the ensure lines of your other resources.
ensure Crimson-Police

# Admins: everyone in group.admin can open the Admin UI (/CrimsonPoliceAdmin).
# Qbox admins can already do this, because config.lua has Config.QboxAdmins = true.
# This line makes sure of it, even if you later set Config.QboxAdmins = false.
add_ace group.admin crimsonpolice.admin allow

# Make one person a Crimson-Police admin only (for example your police chief), not a server admin.
# Put their ID from txAdmin in place of the example, then remove the # at the start.
# add_ace identifier.fivem:1234567 crimsonpolice.admin allow # Chief Smith
# add_ace identifier.license:1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b crimsonpolice.admin allow # Deputy Chief Jones

# Optional Discord webhooks. Remove the # of the ones you want and paste your own link.
# Always use "set", never "setr" (setr would send your webhook link to every player).
# set cp_webhook_board      "https://discord.com/api/webhooks/..."   # weekly top 3, season results
# set cp_webhook_audit      "https://discord.com/api/webhooks/..."   # payout changes, admin actions
# set cp_webhook_flags      "https://discord.com/api/webhooks/..."   # flagged runs, voids, disputes
# set cp_webhook_builder    "https://discord.com/api/webhooks/..."   # Mission Builder: publish, archive, rollback, tests
# set cp_webhook_operations "https://discord.com/api/webhooks/..."   # Cross-Department Missions
```

What each line means:

- `ensure Crimson-Police` starts the resource. Its required resources start themselves first.
- `add_ace group.admin crimsonpolice.admin allow` gives the permission `crimsonpolice.admin` to the group
  `group.admin`. A permission is called an **ace** in FiveM, and a group is called a **principal**. The txAdmin
  owner account is in `group.admin` on a normal Qbox server. Section [4.2](#42-admins) shows how to add more people,
  and how to keep some server admins out of the Admin UI.
- `add_ace identifier.fivem:… crimsonpolice.admin allow` gives the permission to one player only. That player
  gets the Admin UI and nothing else on your server.
- `set cp_webhook_… "…"` turns on one Discord webhook. A `set` line is a **convar**: a setting stored in
  server.cfg. Leave out any you don't want. See [guide 3.6](docs/OWNER_GUIDE.md#36-discord-webhooks).

Nothing else goes in server.cfg for Crimson-Police. There is no command permission to add, and OneSync is already on.

### 3.3 Check your police jobs

Crimson-Police ships with two departments: **SAST** (Qbox job `sast`) and **FIB** (Qbox job `fib`).

- A stock Qbox server only has the jobs `police`, `bcso` and `sasp`. It has **no** `sast` or `fib` job.
- If your `qbx_core/shared/jobs.lua` has `sast` and `fib` (servers that use sc-police often do), you are done.
- If not, open `Crimson-Police/config/config.lua`, find `Config.Departments`, and put your own police job name in
  `jobs`. For example, for the LSPD job of stock Qbox:

  ```lua
  jobs = { 'police' },     -- your Qbox job name(s) for this department
  ```

- Do the same for `fib` (for example with `'bcso'` or `'sasp'`). If you only have one police job, delete the whole
  `fib = { ... },` block. A job name may only be in one department.
- You may also rename a department to match its job: `label` (the full name) and `short` (the tag), and give it
  your own logo. See [guide 2.1](docs/OWNER_GUIDE.md#21-departments-and-jobs).

Then set the grade where supervisors start (`supervisorGrade`, default `3`). Section [guide
2.2](docs/OWNER_GUIDE.md#22-supervisor-grades) explains the number. The start-up check (next step) tells you if a job
name is wrong or if the grade means nobody, or everybody, is a supervisor.

**You can also do all of this in game instead of in the file.** Start the server, type `/CrimsonPoliceAdmin`, open
**Settings**, search for `jobs` or `supervisorGrade`, change the value and press **Save**. Department changes work at
once. See [guide 2.6](docs/OWNER_GUIDE.md#26-change-any-setting-in-game-the-settings-screen).

### 3.4 Start the server and read the console

Start (or restart) your server. About 5 seconds after Crimson-Police starts, it checks your setup and prints the
result. On a good install the console shows lines like these (the order can differ):

```
[crimson-police] storage: database off, data saved as files in the saves folder .../resources/Crimson-Police/saves
[crimson-police] first start with the database off: the saves folder .../resources/Crimson-Police/saves is empty, so Crimson-Police starts with no data
[crimson-police] applied migration 001_initial.sql
[crimson-police] applied migration 002_test_def_hash.sql
...
[crimson-police] Crimson-Police saves folder at version 17
[crimson-police] missions loaded: 19 built-in, 0 custom, 0 rejected
[crimson-police] Start-up check: all 18 checks passed. Type CrimsonPoliceAdmin check in the server console to see them
```

- With the database on, the first line reads `storage: MySQL/MariaDB through oxmysql`, the "first start" line is
  not there, and the version line reads `Crimson-Police database at version 17`. On a database made by txAdmin's
  recipe, the first start also prints one `cp_... is utf8mb3_general_ci: switching it to utf8mb4
  (once)` line per table.
- The `applied migration` lines only show on the first start and after an update. A migration is Crimson-Police
  creating or upgrading its own tables.
- The number of checks on the last line depends on your setup.
- The copy you downloaded has `Config.Debug = true`, so you also see many extra lines that start with
  `[crimson-police:` (for example `[crimson-police:admin] /CrimsonPoliceAdmin registered`). They are normal and help
  while you test. Before go-live, set `Config.Debug = false` in `config/config.lua` for a quiet console (see
  [5.1](#51-the-two-switches-at-the-top-debug-and-storage)).

**If something needs fixing**, you see yellow or red lines instead, one per problem, each with the fix. Then the
last line reads:

```
[crimson-police:confighealth] Start-up check: 1 warnings and 0 errors (each on its own line above, with the fix), 17 checks passed. ...
```

For example, on a stock Qbox server (no `sast` and no `fib` job) you get this line, and the same line for FIB:

```
[crimson-police:confighealth] departments: SAST: Qbox has no job named sast, so nobody can use this department. Add the job to qbx_core/shared/jobs.lua, or put your own police job name in jobs = { } of Config.Departments.sast in config/config.lua
```

Fix what the lines say, then restart Crimson-Police (`ensure Crimson-Police` or `restart Crimson-Police` in the
console, or restart the server). Most of these fixes can also be made in game in Admin UI → **Settings**, where the
check runs again after every change ([guide
2.6](docs/OWNER_GUIDE.md#26-change-any-setting-in-game-the-settings-screen)). To see every check again at any time,
type this in the server console:

```
CrimsonPoliceAdmin check
```

Section [8](#8-troubleshooting) lists every message and what to do.

### 3.5 Open the tablet in game

- **Officers**: be on duty in a department job (SAST or FIB by default), then type `/CrimsonPolice`. Press **Esc**,
  or the **X** at the top right, to close the tablet.
- **Supervisors**: open the tablet, then press **Supervisor** at the bottom of the left sidebar.
- **Admins**: type `/CrimsonPoliceAdmin`. Admins don't need a police job and don't need to be on duty. **Esc**
  closes the Admin UI too.

Quick test as a Qbox admin (these are Qbox commands, not Crimson-Police ones):

1. Type `/optin` (Qbox asks admins to opt in before its admin commands work). It switches on and off: Qbox answers
   "You have successfully opted in for admin duty." If it says "out", type `/optin` again.
2. Type `/id` to see your server ID.
3. Type `/setjob <your server id> sast 3` to give yourself the SAST job at grade 3 (use your own job name if you
   changed it in [3.3](#33-check-your-police-jobs)).
4. Go on duty the way you normally do (for example at an sc-police duty point), then type `/CrimsonPolice`.

Players can also bind keys for the tablet. See [6.2](#62-keys).

---

## 4. Admins, supervisors and permissions

### 4.1 The three roles

| Role | Who | How they get it | What they open |
|---|---|---|---|
| **Officer** | Anyone on duty whose **active** Qbox job is in a department's `jobs` | Their Qbox job. Nothing in server.cfg | The tablet: `/CrimsonPolice` |
| **Supervisor** | An officer whose job grade is at or above that department's `supervisorGrade` | Their Qbox job grade. Nothing in server.cfg | The **Supervisor** button inside the tablet |
| **Admin** | Anyone with the `crimsonpolice.admin` permission, or any Qbox admin while `Config.QboxAdmins = true` | server.cfg (see [4.2](#42-admins)) | `/CrimsonPoliceAdmin`: a full-screen admin panel |

- Admins do not need a police job, a character on duty or even a department. They do need a loaded character for
  the Mission Builder and for test runs.
- Admins are **not** supervisors by themselves. An admin who also wants the Supervisor button needs a department
  job at or above `supervisorGrade`, on duty.
- Every check happens on the server. A hidden button is never the only protection.
- Nobody, admins included, may approve, void or answer a dispute about a run they took part in, or one that another
  character of theirs (any character on the same license) took part in.
- Officers suspended in Crimson-Police or in sc-dispatch can't open the tablet.

### 4.2 Admins

**Qbox admins get access automatically.** `config/config.lua` has `Config.QboxAdmins = true`. On a Qbox server,
the group `group.admin` holds the ace `admin` (a server made with the Qbox txAdmin recipe has the line
`add_ace group.admin admin allow` in its `permissions.cfg`), so everyone in `group.admin` is a Crimson-Police
admin. Moderators (`group.mod`) and support staff (`group.support`) are not.

The line `add_ace group.admin crimsonpolice.admin allow` from [3.2](#32-paste-this-into-servercfg) does the same
thing in a second way. Keep it: it works even if your server has no `add_ace group.admin admin allow` line, or if
you set `Config.QboxAdmins = false`. The start-up check tells you whether `group.admin` can open the Admin UI.

**Who is in group.admin?** On a new Qbox server made with txAdmin, only the txAdmin owner account is. To make
someone else a **full server admin** (Qbox admin and Crimson-Police admin), add one line with one of their IDs:

```cfg
add_principal identifier.fivem:1234567 group.admin # John
add_principal identifier.license:1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b group.admin # John
add_principal identifier.discord:123456789012345678 group.admin # John
```

(One line is enough. The text after `#` is only a note for you.)

**Only the tablet, not the whole server.** A full server admin can run every server command. For someone who
should only run Crimson-Police (a police chief, for example), give just the Crimson-Police permission:

```cfg
add_ace identifier.fivem:7654321 crimsonpolice.admin allow # Chief Smith
```

For several people, make a small group once, then add each person to it:

```cfg
add_ace group.cpadmin crimsonpolice.admin allow
add_principal identifier.fivem:7654321 group.cpadmin # Chief Smith
add_principal identifier.license:0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6 group.cpadmin # Deputy Chief Jones
```

**Only if your server has a god group** (some servers moved from QBCore have `group.god`):

```cfg
add_ace group.god crimsonpolice.admin allow
```

**How to find a player's ID.** Two easy ways:

- The easiest: ask the player to type `/CrimsonPoliceAdmin` once. They get "Only admins can open the Admin UI.", and
  your server console gets one line with the exact line to paste, their ID included: `John (server id 3) typed
  /CrimsonPoliceAdmin but is not an admin. To make them one, add this line to server.cfg and restart: add_ace
  identifier.fivem:1234567 crimsonpolice.admin allow`
- Or in the txAdmin web panel: **Players**, click the player, open the **IDs** tab. It lists `license:…`,
  `fivem:…` and `discord:…`. In server.cfg, put `identifier.` in front: `fivem:1234567` becomes
  `identifier.fivem:1234567`. The `fivem:` ID is the same on every PC.

**Apply a change.** Restart the server after you edit server.cfg. Or paste the same line into txAdmin's **Live
Console** to apply it at once (a line typed there is forgotten on restart unless it is also in server.cfg). The
player then closes and reopens the tablet.

**Take access away.** Delete the line and restart, or type in the Live Console:

```cfg
remove_principal identifier.fivem:1234567 group.admin
remove_ace identifier.fivem:7654321 crimsonpolice.admin allow
```

**The two admin settings in config/config.lua:**

```lua
Config.AdminAce = 'crimsonpolice.admin'     -- the admin permission; supervisors come from job grade
Config.QboxAdmins = true                    -- true = your Qbox admins are Crimson-Police admins too; false = only AdminAce
```

- If you rename `Config.AdminAce`, use your new name in every `add_ace` line instead of `crimsonpolice.admin`.
- `Config.QboxAdmins = false` means only players with `Config.AdminAce` are admins. Use it if you want a separate
  Crimson-Police admin team. Then also delete the line `add_ace group.admin crimsonpolice.admin allow` from
  server.cfg ([3.2](#32-paste-this-into-servercfg)): while it is there, everyone in `group.admin` stays an admin.
  Give the ace to your team instead (one `add_ace identifier.… crimsonpolice.admin allow` line each, or the small
  group shown above).
- While `Config.QboxAdmins = true`, a `deny` on `crimsonpolice.admin` does not stop a Qbox admin. To keep one Qbox
  admin out, do the same: set `Config.QboxAdmins = false`, delete the `add_ace group.admin …` line, and give the
  ace to the others yourself.
- A `config.lua` kept from an older version has no `Config.QboxAdmins` line. Then only `Config.AdminAce` counts,
  exactly as before, so an update never adds admins by itself.

### 4.3 Supervisors

Supervisors are set only in `config/config.lua`, one number per department. Nothing goes in server.cfg.

```lua
-- shortened: config/config.lua has the whole block
Config.Departments = {
    sast = {
        jobs = { 'sast' },        -- your Qbox job name(s) for this department
        supervisorGrade = 3,      -- Qbox grade number: this grade and up are supervisors
        ...
```

**Finding the number.** Open the file where your jobs are defined (`qbx_core/shared/jobs.lua` on a normal Qbox
server). Each grade is written like `[3] = { name = 'Lieutenant', ... }`. The number in brackets is the grade.
Grades start at 0.

| Where the grades come from | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|
| Stock Qbox `police`, `bcso` and `sasp` | Recruit | Officer | Sergeant | Lieutenant | Chief | | |
| sc-police's grade notes | Recruit | Trooper | Senior Trooper | Corporal | Sergeant | Lieutenant | Captain |

- The shipped value `3` makes a stock Qbox Lieutenant and up a supervisor, or an sc-police Corporal and up.
- sc-dispatch treats grade 4 and up as command staff (`Config.Roster.CommandGrade = 4` in sc-dispatch).
- `CrimsonPoliceAdmin check` (and Admin UI → **Permissions** → **Config health**) lists each department's grades
  and where supervisors start, for example
  `SAST: Qbox job sast (0 Recruit, 1 Trooper, ...); supervisors are grade 3 Corporal and up`. At start the console
  warns when the number is higher than every grade (nobody is a supervisor) or the lowest grade (everybody is).
- A department with several jobs (`jobs = { 'sast', 'sasp' }`) uses one `supervisorGrade` for all of them.

The Supervisor UI layout switches, the Department screen and every supervisor permission are in [guide
1](docs/OWNER_GUIDE.md#1-supervisors-in-detail).

### 4.4 Things only admins can do

Every admin tool is a button in `/CrimsonPoliceAdmin`, needs a reason and goes into the audit log: [guide
1.4](docs/OWNER_GUIDE.md#14-what-admins-can-do-in-the-admin-ui) lists them.

**What stays out of the tablet, on purpose**: who is an admin (server.cfg, and `Config.AdminAce` /
`Config.QboxAdmins` in config.lua, shown locked in Settings), Discord webhook links (server.cfg only, never shown in
game), and restarting Crimson-Police (txAdmin or the server console; Crimson-Police never restarts itself).

These are always admin only. Setting one of them to `true` in `Config.Permissions.supervisor` does nothing.

- Open the Admin UI.
- Change settings in game (Admin UI → **Settings**), and turn missions and locations on or off.
- Set or clear the payout of **one** mission, and clear any admin-set payout.
- Give points by hand (manual award), apart from the **Give points** Mission control you may switch on
  for supervisors.
- Answer disputes about **failed** runs.
- Void any run.
- Start and end seasons, and override the weekly bounty.
- Suspend and unsuspend officers.
- Give or take points (add or take away), void and restore runs in bulk, retire officers, move a record, fix XP, grant
  and revoke badges, and the other officer, board and season tools of [guide
  5.15.1](docs/OWNER_GUIDE.md#5151-officers-points-and-boards).
- Reload mission files.
- Start test runs.

### 4.5 The server console

- The server console (and txAdmin's **Live Console**) always counts as an admin.
- Every `/CrimsonPoliceAdmin` command works there too, typed **without the slash**, for example
  `CrimsonPoliceAdmin storage`. `CrimsonPoliceAdmin help` lists them all.
- Only `test` (and opening the Admin UI itself) needs you in game.
- **Three console-only controls** bring the Admin UI back when it can't open. Nothing else needs the console:
  - `CrimsonPoliceAdmin settings` lists the settings changed in game. `CrimsonPoliceAdmin settings reset <path>`
    puts one back to its config.lua value (for example `settings reset Cash.source`), and
    `CrimsonPoliceAdmin settings reset all` puts every one back.
  - `CrimsonPoliceAdmin storage mode reset` (or `storagemode reset`) forgets a storage switch made in game: the next
    start uses `Config.Database` from config.lua again. Restart Crimson-Police afterwards. It also works after a
    start that failed (then it and `CrimsonPoliceAdmin check` are the only commands that do): type
    `ensure Crimson-Police` afterwards ([guide 8.1](docs/OWNER_GUIDE.md#81-database-and-saves-folder)).
  - `set cp_settings_safe 1` in server.cfg starts Crimson-Police once with config.lua only: the settings changed in
    game are ignored, not deleted. Remove the line (or set it to `0`) and restart to use them again.
- Section [6.1](#61-commands) lists every command.

### 4.6 Common mistakes

- Don't add `add_ace group.admin command.CrimsonPoliceAdmin allow`. It is not needed: the command checks
  `crimsonpolice.admin` itself.
- **Never** add `add_ace builtin.everyone crimsonpolice.admin allow`. It makes every player an admin.
- Only add `add_ace group.mod crimsonpolice.admin allow` if you really want moderators to change payouts, suspend
  officers and void runs.
- Don't put someone in `group.admin` just for the tablet. Use the tablet-only line in [4.2](#42-admins) instead:
  `group.admin` can run every server command.
- `supervisorGrade` is a grade **number**, not a grade name.

---

## 5. Debug, storage and what ships off

### 5.1 The two switches at the top: debug and storage

The top of `config/config.lua` has two switches. **In the copy you downloaded, both are set like this:**

```lua
Config.Debug = true              -- true = each module prints tagged debug lines

Config.Database = {
    enabled = false,
    folder = 'saves',
    -- Files mode: after this many milliseconds of saving, Crimson-Police lets the server run its other work for a
    -- moment before the next save (what oxmysql does in database mode); 0 = never pause (the old timing)
    saveTurnMs = 4,
    -- Files mode: how many answers of JSON lookups (badge counts read every run of an officer) are kept; about 50 bytes
    -- each, 100000 = about 5 MB; 20000 = the old size; 0 = keep none
    jsonCacheEntries = 100000,
}
```

- **Debug is on for testing.** `Config.Debug = true` prints many extra `[crimson-police:…]` lines in the console.
  Leave it on while you set up and test: the extra lines help when something goes wrong. **Before go-live**, set
  `Config.Debug = false` and restart Crimson-Police for a quiet console.
- **The database is off.** `Config.Database.enabled = false` saves everything as files in `Crimson-Police/saves`, with
  no database tables. Nothing to set up. Section [guide 3.5](docs/OWNER_GUIDE.md#35-database-off-the-saves-folder)
  explains the folder.
- **To turn the database on** and keep everything in your MySQL/MariaDB database instead:
  1. Check that oxmysql connects. Qbox already uses it, through the `set mysql_connection_string` line in your
     `server.cfg`, so on a working Qbox server there is nothing to add.
  2. Set `enabled = true` in `Config.Database`.
  3. Restart Crimson-Police. It makes its own tables on the first start (there is no SQL to import). The console
     then says `storage: MySQL/MariaDB through oxmysql`.
- Both work the same for players. Switching does not move your data by itself: on a server that already has data, read
  "Switching on a server that already has data" in [guide 3.5](docs/OWNER_GUIDE.md#35-database-off-the-saves-folder)
  first. The copy to the database switches its tables to `utf8mb4` too, so on a database made by txAdmin's recipe the
  names and reasons with emoji in your saves folder come along.

### 5.2 What ships off and how to turn it on

Crimson-Police ships so that a new server runs plain NPC missions with points and cash, and nothing that
involves real players as suspects, extra money or item rewards. Every switch below is one setting: turn it on
in game in Admin UI → **Settings** → **Features** (it works at once, is audited, and **Reset** puts the
`config.lua` value back), or set it to `true` in `config/config.lua` and restart Crimson-Police.

The two switches at the top ([5.1](#51-the-two-switches-at-the-top-debug-and-storage)) ship for testing:
`Config.Debug = true` (extra console lines; set `false` before go-live) and `Config.Database.enabled = false`
(data in the `saves/` folder). Testing a mission is never required: `Config.Builder.requireTestToPublish = false`.

**Ships off** (the Features tab shows them as Off):

| Feature (name in the Features tab) | Section | Switch | More |
|---|---|---|---|
| Extra parts of a mission on the map (in the Map markers row) | NPC missions | `Config.Markers.extraParts` | [guide 3.13](docs/OWNER_GUIDE.md#313-map-markers-every-part-of-a-mission) |
| Live crimes (real players) | Player vs police | `Config.LiveCrime.enabled` | [guide 6](docs/OWNER_GUIDE.md#6-real-suspects-live-crimes-and-volunteers) |
| Volunteer suspects | Player vs police | `Config.Volunteers.enabled` | [guide 6](docs/OWNER_GUIDE.md#6-real-suspects-live-crimes-and-volunteers) |
| Criminal tablet for volunteer suspects | Player vs police | `Config.CriminalTablet.enabled` | [guide 6.5](docs/OWNER_GUIDE.md#65-the-criminal-tablet) |
| Cash for live cases | Player vs police | `Config.LiveCrime.cash` | [guide 6](docs/OWNER_GUIDE.md#6-real-suspects-live-crimes-and-volunteers) |
| Item rewards for live cases | Player vs police | `Config.LiveCrime.items` | [guide 6](docs/OWNER_GUIDE.md#6-real-suspects-live-crimes-and-volunteers) |
| Cash for volunteer cases | Player vs police | `Config.Volunteers.payCash` | [guide 6](docs/OWNER_GUIDE.md#6-real-suspects-live-crimes-and-volunteers) |
| Item rewards for volunteer cases | Player vs police | `Config.Volunteers.payRewards` | [guide 6](docs/OWNER_GUIDE.md#6-real-suspects-live-crimes-and-volunteers) |
| Supervisor mission controls | Police teamwork | `Config.Permissions.supervisor.missionControls` | [guide 1.2](docs/OWNER_GUIDE.md#12-what-supervisors-may-do) |
| Field training (FTO) | Police teamwork | `Config.FieldTraining.enabled` | [guide 3.11](docs/OWNER_GUIDE.md#311-field-training-fto) |
| Avatar image links | Police teamwork | `Config.Profile.avatarUrls.enabled` | [guide 3.4](docs/OWNER_GUIDE.md#34-profile-pictures) |
| Item rewards | Economy and rewards | `Config.Rewards.enabled` | [guide 3.3](docs/OWNER_GUIDE.md#33-item-rewards) |
| Pay volunteer suspects | Economy and rewards | `Config.FeatureRewards.suspect.enabled` | [guide 3.12](docs/OWNER_GUIDE.md#312-feature-rewards-money-and-items-for-every-feature) |
| Pay talk-downs | Economy and rewards | `Config.FeatureRewards.surrender.enabled` | [guide 3.12](docs/OWNER_GUIDE.md#312-feature-rewards-money-and-items-for-every-feature) |
| Pay field training sign-offs | Economy and rewards | `Config.FeatureRewards.ftoSignOff.enabled` | [guide 3.12](docs/OWNER_GUIDE.md#312-feature-rewards-money-and-items-for-every-feature) |
| Pay finished field training | Economy and rewards | `Config.FeatureRewards.ftoComplete.enabled` | [guide 3.12](docs/OWNER_GUIDE.md#312-feature-rewards-money-and-items-for-every-feature) |
| Pay supervisor point awards | Economy and rewards | `Config.FeatureRewards.supAward.enabled` | [guide 3.12](docs/OWNER_GUIDE.md#312-feature-rewards-money-and-items-for-every-feature) |
| Daily backup | System | `Config.Backups.daily` | [guide 7.3](docs/OWNER_GUIDE.md#73-backups) |

**Admin money tools** ship off too. They are not in the Features tab: turn one on in Admin UI → **Settings**
(All settings), where turning it on needs the typed word **ENABLE** (see
[guide 5.15.4](docs/OWNER_GUIDE.md#5154-payments-item-rewards-and-department-money)):

- `Config.Cash.allowUnfundedRetry`
- `Config.Cash.allowCapTopUp`
- `Config.Cash.allowPayAgain`
- `Config.Cash.restoreForfeited`
- `Config.Cash.allowAddFunds`
- `Config.Cash.allowClawback`
- `Config.Cash.allowManualCash`
- `Config.Rewards.allowTakeBack`

**Ships on** (the Features tab shows them as On; turn one off the same way):

| Feature (name in the Features tab) | Section | Switch |
|---|---|---|
| Safe spawning (people appear out of sight) | NPC missions | `Config.Spawning.enabled` |
| NPC combat rules | NPC missions | `Config.NpcCombat.enabled` |
| Runners tire (sprint, jog, walk) | NPC missions | `Config.Flee.enabled` |
| Tell hints on the HUD | NPC missions | `Config.Npc.tellHints` |
| Rescale when officers leave | NPC missions | `Config.Rescale.enabled` |
| Map markers: the objective pointer and every part of a mission | NPC missions | `Config.Markers.enabled` |
| Follow the GPS route to the start | NPC missions | `Config.Route.required` |
| Mission calls | NPC missions | `Config.MissionCalls.enabled` |
| Reopen abandoned mission calls | NPC missions | `Config.MissionCalls.reopen.enabled` |
| Type of the Day | NPC missions | `Config.Events.typeOfTheDay` |
| Weekly boss mission | NPC missions | `Config.Events.weeklyBoss.enabled` |
| Twist: Armored Hostiles | NPC missions | `Config.Events.twists.armored_hostiles.enabled` |
| Twist: Radio Silence | NPC missions | `Config.Events.twists.radio_silence.enabled` |
| Twist: Time Crunch | NPC missions | `Config.Events.twists.time_crunch.enabled` |
| Tow truck for impounds | NPC missions | `Config.Custody.tow.enabled` |
| Decision debrief on the result screen | NPC missions | `Config.Decisions.debrief` |
| Mission Builder for supervisors | NPC missions | `Config.Builder.enabled` |
| Surrender and talk-down | Player vs police | `Config.RealSuspects.surrender.enabled` |
| Real suspects admin screen | Player vs police | `Config.RealSuspects.adminScreen` |
| Cross-department operations | Police teamwork | `Config.CrossDept.enabled` |
| Unit ready check | Police teamwork | `Config.Units.readyCheck` |
| Commendations | Police teamwork | `Config.Commendations.enabled` |
| Department challenge | Police teamwork | `Config.Challenge.enabled` |
| Weekly top 3 announcement | Police teamwork | `Config.Leaderboard.announceWeekly` |
| Monthly top 3 announcement | Police teamwork | `Config.Leaderboard.announceMonthly` |
| Officers set their own options | Police teamwork | `Config.OfficerOptions.enabled` |
| Admin test mode | System | `Config.Testing.enabled` |
| Spawn check in test mode | System | `Config.Testing.spawnCheck.enabled` |

---

## 6. All commands and keys

### 6.1 Commands

In the server console, type every command **without** the slash.

| Command | Who can use it | What it does |
|---|---|---|
| `/CrimsonPolice` | Officers (on duty, department job) | Opens the tablet (**Esc** or the **X** closes it) |
| `/CrimsonPoliceAdmin` | Admins, in game | Opens the Admin UI. Typed in the server console, it lists the subcommands |
| `CrimsonPoliceState` | Anyone, in the **F8** console | Prints what holds the screen, the NUI focus, the camera and the controls right now, and which part is Crimson-Police's. `CrimsonPoliceState unstick` releases only Crimson-Police's own (see [8.4](#84-the-screen-froze-or-the-controls-stopped)) |
| `/CrimsonPoliceAdmin help` | Admins, console | Lists every subcommand (in game: a one-line list) |
| `/CrimsonPoliceAdmin check` | Admins, console | Runs the start-up check again. The console lists every line; in game you get the counts |
| `/CrimsonPoliceAdmin payout type <type> <amount\|clear> <reason>` | Admins, console | Sets a mission type's payout for good, or clears it back to `config.lua`. Type = `patrol`, `training`, `investigation` or `tactical`. Example: `payout type tactical 1000 Summer event` |
| `/CrimsonPoliceAdmin payout mission <missionId> <amount\|clear> <reason>` | Admins, console | Sets or clears one mission's payout. Example: `payout mission gang_shootout 1200 Harder than the rest` |
| `/CrimsonPoliceAdmin award <citizenid> <points> <reason>` | Admins, console | Gives points by hand (1 to 10,000). The citizenid is the character ID Qbox gives each character: Admin UI → **Officers** shows it under the officer's name |
| `/CrimsonPoliceAdmin season start <name>` | Admins, console | Starts a season (and its department challenge) |
| `/CrimsonPoliceAdmin season end` | Admins, console | Ends the current season |
| `/CrimsonPoliceAdmin suspend <citizenid> <days> [reason]` | Admins, console | Blocks an officer from Crimson-Police for that many days. `0` lifts it |
| `/CrimsonPoliceAdmin reload` | Admins, console | Reloads built-in and custom mission files without a restart |
| `/CrimsonPoliceAdmin test <missionId> [tier] [location\|random]` | Admins, **in game only** | Starts a test run (see [guide 5.13](docs/OWNER_GUIDE.md#513-testing-tools)). Tier = `standard`, `reinforced`, `heavy`, `major`, `critical` or `auto`; location = a number or `random` |
| `/CrimsonPoliceAdmin storage` | Admins, console | Shows the storage in use, the rows of every table and the saves folder size |
| `/CrimsonPoliceAdmin storage copy database-to-files [force]` | Admins, console | Copies everything from the database to the saves folder ([guide 3.5](docs/OWNER_GUIDE.md#35-database-off-the-saves-folder)) |
| `/CrimsonPoliceAdmin storage copy files-to-database [force]` | Admins, console | Copies everything from the saves folder to the database |
| `CrimsonPoliceAdmin storage mode reset` | Console only | Forgets a storage switch made in Admin UI → **System**: the next start uses `Config.Database` from config.lua. `CrimsonPoliceAdmin storagemode reset` does the same |
| `CrimsonPoliceAdmin settings` | Console only | Lists every setting changed in game (Admin UI → **Settings**) |
| `CrimsonPoliceAdmin settings reset <path>` | Console only | Puts one setting back to its config.lua value. Example: `settings reset Cash.source` |
| `CrimsonPoliceAdmin settings reset all` | Console only | Puts every setting changed in game back to config.lua |
| `/CrimsonPoliceAdmin missioncall <type> [area]` | Admins, console | Posts a mission call now. Type = `patrol`, `investigation` or `tactical`. Area = `south_ls`, `downtown`, `west_ls`, `vinewood`, `east_ls`, `port`, `senora`, `north`, `west_county` or `county` (the default). Not while a Cross-Department Mission runs; 2 minutes between calls from the same person (the console counts as one) |
| `/crimsonheat` | Players who are **not** on police duty, only with `Config.Volunteers.enabled = true` | Volunteers to play a mission's suspect for `Config.Volunteers.windowMinutes` (60): agree to the rules, tick the suspects to play. Typed again it opens the menu (time left, Renew, Change the suspects you play, Stop, and Cancel this case while you play one). The name is `Config.Volunteers.command` (restart to change it). See [guide 6](docs/OWNER_GUIDE.md#6-real-suspects-live-crimes-and-volunteers) |
| `/crimtab` | Players who are **not** on a police job (or who hold the `criminalTablet` extra grant), only with `Config.CriminalTablet.enabled = true`; never on police duty | Opens the criminal tablet: Home (get on or off the volunteer list), Jobs, Active, History and Rules. The name is `Config.CriminalTablet.command` (restart to change it). See [guide 6.5](docs/OWNER_GUIDE.md#65-the-criminal-tablet) |
| `/surrender` | A suspect of a live case, only with `Config.LiveCrime.enabled = true` | Asks him to confirm, then surrenders him to the officers of his case (one must be within `Config.RealSuspects.surrender.surrenderRange`, 50 m). The name is `Config.RealSuspects.surrender.command` (restart to change it). See [guide 6.2](docs/OWNER_GUIDE.md#62-rules-for-cases-with-real-suspects) |

"Admins, console" means an admin in game **and** the server console. "Console only" commands are the three ways
back in for when the Admin UI can't open ([4.5](#45-the-server-console)). Mission ids (for `payout mission` and `test`)
are in [guide 5.4](docs/OWNER_GUIDE.md#54-the-missions).

Reasons are required for payout changes (`Config.Payouts.requireReason = true`). Every admin action is written to
the audit log (Admin UI → **Audit Log**).

### 6.2 Keys

Only the test panel has a default key (F7, `Config.Testing.panelKey`). Players bind the others themselves: **ESC →
Settings → Key Bindings → FiveM**, then look for the Crimson-Police lines.

| Name in the key list | What it does | Default |
|---|---|---|
| Open the Crimson-Police tablet | Same as `/CrimsonPolice` | none (`Config.Tablet.keybind`) |
| Crimson-Police: open Dispatch | Opens the tablet on the Dispatch screen | none (`Config.Tablet.dispatchKey`) |
| Crimson-Police: ready for the unit's mission | Answers a unit ready check with Ready | none (`Config.Tablet.readyKey`) |
| Crimson-Police: contact action (plate, place in vehicle, hand over, escort) | The police action shown on screen during a mission | none (`Config.Tablet.contactKey`) |
| Crimson-Police: test controls and invitations | Test run controls for admins, or the test invitation for testers. Press again to free the mouse | **F7** (`Config.Testing.panelKey`) |

- A default key you set in `config.lua` only reaches players who never had that key before. Players who already
  joined keep their own choice.
- Escape closes a dialog in the tablet first, then the tablet, when you let go of it. For 300 ms after the tablet
  closes the GTA pause menu stays shut, so the same Escape does not open it (`Config.Tablet.pauseGuardMs`, 0 = off).
  The test controls key also acts when you let go of it. Bound to a mouse or pad button, the test panel shows
  **Esc** only (Escape frees the mouse) and the test invitation toast names no key.
- Mission Builder keys, shown on screen while you use a builder tool: **E** (or the horn) place or set,
  **Backspace** undo, **Enter** done or finish, **P** pause or resume, **X** stop point, close or stop a test drive,
  **mouse wheel** radius or rotate, **Shift** fine steps. While placing points, **X** cancels (the points stay as they
  were), and **Delete** (or Backspace) while aiming at a placed point within 1.5 m removes that point. The placing
  HUD shows how many points are needed and placed, and how far from the start the points must stay.

---

## 7. Admin UI tour

`/CrimsonPoliceAdmin` opens a full-screen panel for every department. One line per screen; the full tour and every
admin tool are in [guide 5.3](docs/OWNER_GUIDE.md#53-the-admin-panel) and
[guide 5.15](docs/OWNER_GUIDE.md#515-full-admin-control). The sidebar is organised by job: Home, then People,
Missions, Real players, Money, Review and System. The search box at the top (or **Ctrl+K**) jumps to any screen or
tab, officer, mission or setting. [Guide 2.9](docs/OWNER_GUIDE.md#29-baked-in-one-way-to-do-each-thing) lists the
old layout switches and where each one lives now.

| Group | Screen | What it is for |
|---|---|---|
| | **Home** | Where the panel opens: a dashboard of **Live now** (officers on duty, runs going, the queues waiting: review, disputes, stuck payments), **Alerts** (problems, refused starts, Config health) and your **Shortcuts** (`Config.AdminUi.homeShortcuts`: new mission, missions on or off, change pay, give or take points, quick settings) |
| People | **Officers** | Search officers: history, suspensions, disputes about failed runs, commendations and the officer tools |
| | **Departments** | Each department's jobs, colours, logo, desks, members and (with society payouts) account balance |
| | **Permissions** | What supervisors may do, the extra grants, the Mission controls and the config health check |
| | **Leaderboards**, **Seasons** (under More) | Every board, cash paid, voids, awards, item rewards; start, plan or end a season, the bounty |
| Missions | **Missions** | Built-in and custom missions: the Mission Builder, publish, archive, restore, roll back, reload files, Cross-Department Missions and mission calls; the switches turn a mission or one location on or off |
| | **Running now** | Every live run and unit: recall, end, add time, split a unit, and the starts the server refused |
| | **Map markers**, **Test tools** | How each part of a mission shows on the map; optional test results, test runs and testers |
| Real players | **Player suspects** | Live crimes, volunteers, surrender and talk-down, the pair ledger, blocks and exclusions (the group shows only while live crimes or volunteers are on) |
| Money | **Money** | Pay rates, feature rewards, every payment made or owed (with the payment tools) and the department funds |
| Review | **Review** | Flagged runs (approve or void), profiles waiting (pictures, bios, reports, banned words), open disputes and corrections (with Undo) |
| | **Activity log** | Every supervisor and admin action, with filters and a CSV export |
| System | **Settings** | Every setting of `config.lua` and `blocks.lua`, changed in game with its description, a Features tab and a change history |
| | **Server health** | Storage, backups, webhook states, recent problems, the other resources and the nightly clean-up |

---

## 8. Troubleshooting

Crimson-Police lines in the console start with `[crimson-police]`. Yellow `[crimson-police:<part>]` lines are
warnings and red ones are errors. Most start-up lines already say what to do.

The console lines about config.lua and departments, missions and the Mission Builder, payments and webhooks are in
[guide 8](docs/OWNER_GUIDE.md#8-more-console-lines).

### 8.1 The tablet does not open

What the player sees, and what to do:

| Message | Why | Fix |
|---|---|---|
| "Crimson-Police is only for officers whose active job belongs to a department." | Their active job is not in any department's `jobs`, or the job doesn't exist in Qbox | Check [3.3](#33-check-your-police-jobs) and the start-up check's `departments` lines. With sc-multijob, the police job must be the **active** one |
| "You need to be on duty to use Crimson-Police." | Off duty | Go on duty |
| "You are suspended from Crimson-Police." | Suspended by an admin or by 3 voided runs | Admin UI → **Officers**, or `/CrimsonPoliceAdmin suspend <citizenid> 0` lifts it |
| "You are suspended in SC-Dispatch and cannot use Crimson-Police." | Suspended in sc-dispatch | Lift it in sc-dispatch |
| "You need the police tablet in your inventory." | `requireItem = true` and no item | Give them the item, or set `requireItem = false` ([guide 3.1](docs/OWNER_GUIDE.md#31-the-tablet-item)) |
| "That way of opening the tablet is switched off on this server." | That way is `false` in `Config.Tablet.access`, or they used the item while `Config.Tablet.item` is not set | Switch it on, or use another way |
| "This mission desk is not for your department." | The desk's `departments` doesn't list theirs | Change the desk's `departments` ([guide 3.2](docs/OWNER_GUIDE.md#32-mission-desks)) |
| "Stand at the mission desk to open the tablet there." | Too far from the desk | Stand at the desk |
| "You can't take a mission while you are in the arena." | They are in Crimson-Arena | Leave the arena |
| "Only supervisors can open the Supervisor UI." | Grade below `supervisorGrade` | [4.3](#43-supervisors) |
| The item does nothing | The item name or `export` line is wrong, or `Config.Tablet.item` is not set | Read the start-up check's `items` lines ([guide 3.1](docs/OWNER_GUIDE.md#31-the-tablet-item)) |

**Quickest check:** Admin UI → **Officers** → the officer → **Support** → **Check access** runs the same checks
the tablet makes and says which one fails and how to fix it. **Give tablet item** hands them one tablet when they
carry none, and **Release screen** frees a stuck tablet screen.

On the Mission Board, "Server busy: too many missions are running. Try again shortly." means 12 missions (or 4
Tactical) are running server-wide (`Config.Limits`). "You are responding to a real call." means they are on a real
sc-dispatch call. "Mission calls are turned off on this server." means `Config.MissionCalls.enabled = false`.

### 8.2 Admin UI

| What you see | Fix |
|---|---|
| "Only admins can open the Admin UI." | The player is not an admin. The server console prints one line with their name and the exact `add_ace identifier.… crimsonpolice.admin allow` line to paste ([4.2](#42-admins)) |
| Start-up check: `admins: No admin group can open the Admin UI yet. Add this line to server.cfg and restart: add_ace group.admin crimsonpolice.admin allow ...` | Add the line from [3.2](#32-paste-this-into-servercfg). Ignore it if you give the ace to each admin yourself |
| "Load a character before using the Mission Builder." / "Load a character first." | The Builder and test runs need a loaded character |
| "Test mode is turned off in Config.Testing." | Set `Config.Testing.enabled = true` |
| "The Mission Builder is turned off." | Set `Config.Builder.enabled = true` |
| "You (or one of your characters) took part in this run, so you can't review it." | By design: you, or another character on your license, was on that run, so another supervisor or admin must review it |
| "That feature is not available on this server right now." | A part of Crimson-Police failed to start. Read the red lines in the console from the last start |

### 8.3 Start-up check lines

These print about 5 seconds after start (only the problems), and all of them with `CrimsonPoliceAdmin check`. They
also show in Admin UI → **Permissions** → **Config health**. Each line starts with the name of the check.

| Line starts with | Means | Fix |
|---|---|---|
| `departments: <DEPT>: Qbox has no job named <job>, so nobody can use this department` | The job is not in Qbox | Add the job to `qbx_core/shared/jobs.lua`, or change `jobs` ([3.3](#33-check-your-police-jobs)) |
| `departments: <DEPT>: Qbox has no job named <job>, so that name does nothing` | One of several job names is wrong | Fix or remove that name in `jobs` |
| `departments: <DEPT>: supervisorGrade is <n>, higher than every grade` | Nobody is a supervisor | Lower `supervisorGrade` ([4.3](#43-supervisors)) |
| `departments: <DEPT>: supervisorGrade <n> is the lowest grade` | Everybody is a supervisor | Raise `supervisorGrade`, unless you want that |
| `departments: Qbox gave no job list` | qbx_core had a problem | Read qbx_core's own lines in the console |
| `admins: No admin group can open the Admin UI yet` | `group.admin` has no admin permission | [4.2](#42-admins) |
| `resources: sc-police is not running` | sc-police is stopped | Add `ensure sc-police` if you use it |
| `folder: This resource's folder is named <name>, not Crimson-Police` | The folder was renamed and the tablet item is on | Rename the folder back to `Crimson-Police`, or change the item's line to `export = '<name>.useTablet'` |
| `items: <item> is not an ox_inventory item` | The item was not pasted into ox_inventory | [guide 3.1](docs/OWNER_GUIDE.md#31-the-tablet-item) step 1, then restart ox_inventory |
| `items: ox_inventory/web/images has no <item>.png` | The picture was not copied | [guide 3.1](docs/OWNER_GUIDE.md#31-the-tablet-item) step 2 |
| `items: ox_inventory is not running` | ox_inventory is stopped | Start ox_inventory |
| `items: requireItem is on but Config.Tablet.item is not set` | Only desks can open the tablet | Set `Config.Tablet.item`, or `requireItem = false` |
| `items: <item> is set but Config.Tablet.access.item is false` | Using the item does nothing | Set `item = true` in `Config.Tablet.access` |
| `desks: Desk <n> (<label>): coords is not a vec3` | A desk has bad coordinates | Write it as `vec3(x, y, z)` |
| `desks: Desk <n> (<label>): size is not a vec3` | A desk's size is written wrong | Write it as `vec3(1.2, 0.8, 1.0)` |
| `desks: Desk <n> (<label>): unknown department <x>` | A desk names a department that doesn't exist | Fix `departments` of that desk |
| `desks: ox_target is not running` | No desk can work | Start ox_target |
| `colours: <DEPT>: theme.<key> is not a 6-digit hex colour` | A colour is written wrong | Write it like `'#1f4e8c'` |
| `colours: <DEPT>: personal accent <n> ...` | An entry of `personalAccents` is wrong or listed twice | Write it like `'#4cc9f0'` or `{ colour = '#80ed99', level = 10 }` |
| `tweaks: Config.MissionTweaks.<id>: there is no mission with that id` | A tweak names an unknown mission | Fix the id ([guide 5.4](docs/OWNER_GUIDE.md#54-the-missions)) |
| `tweaks: Config.MissionTweaks.<id> was ignored` | The tweak breaks a mission rule | The console line from the start says why |
| `locale: locales/en.json is missing` / `is not valid JSON` | The text file is broken | Copy `locales/en.json` again from the download |
| `avatars: ...` | A picture host is wrong or expires | [guide 3.4](docs/OWNER_GUIDE.md#34-profile-pictures) |
| `webhooks: cp_webhook_<name> in server.cfg is not an https:// link` | A webhook link is wrong | `set cp_webhook_<name> "https://discord.com/api/webhooks/..."` |
| `rewards: Item rewards: "<item>" (<pool>) does not exist in ox_inventory` | A reward item is unknown; it is turned off | Use an item that exists ([guide 3.3](docs/OWNER_GUIDE.md#33-item-rewards)) |
| `rewards: Item rewards: "<item>" (<pool>) can never be an item reward` | A forbidden item (weapon, ammo, money ...) | Pick another item |
| `rewards: Item rewards: example item "<item>" (<pool>) does not exist in ox_inventory` | Your ox_inventory has no `water`, `burger` or `sprunk` (the example items). This shows even while item rewards are off | Harmless while `useExamplePools = false`. To use item rewards, fill `byType` with your own items ([guide 3.3](docs/OWNER_GUIDE.md#33-item-rewards)) |
| `rewards: Item rewards: ox_inventory is not started` | Item rewards are on but ox_inventory is stopped | Start ox_inventory |
| `This check could not run: the server console has the error` | A check crashed | Read the red line in the console |

The last line of the start-up check is `Start-up check: all ... checks passed` or
`Start-up check: <n> warnings and <n> errors (each on its own line above, with the fix) ...`.

### 8.4 The screen froze or the controls stopped

First tell the two cases apart. They have different causes.

- **The whole picture stopped** (the world, the HUD and the mouse), F8 does not open, and you had to close the game
  from Task Manager. That is a script that never gives the game a turn (a loop with no `Wait`). The game writes no
  error and no crash log for it. Crimson-Police's own loops are checked for this on every change (`tools/lint_fivem.py`
  rule FX10), so look at the resource you used just before. Note the time. On the server, the player then drops with a
  timeout instead of "Exiting".
- **The world still moves but you cannot do anything.** Press **F8** and type `CrimsonPoliceState`. The last line
  says what is stuck and whether it is Crimson-Police's: a fade, the NUI focus (a mouse cursor), a scripted camera,
  player control, a frozen player, or sc-ambulance still counting you as down. `CrimsonPoliceState unstick` closes the
  tablet and removes the pick-up fade, and nothing else.

Crimson-Police closes the tablet when you go down (dead or last stand), and it does not open again until you are back
up. It releases the NUI focus when the tablet page shows nothing. The downed pick-up always fades the screen back in,
however it ends.

### 8.5 Restarting ox_inventory while Crimson-Police runs

You do not need to restart Crimson-Police after `restart ox_inventory`. What happens:

| While ox_inventory is stopped | Once it has started again |
|---|---|
| Mission items can be moved, given or dropped (the lock lives in ox_inventory) | The lock on mission items is registered again about 1 s after ox_inventory starts |
| A mission accepted now gives no mission items (one console line: `ox_inventory is not started: mission items are not given`) | Missions accepted from now on give their items again |
| Mission items to take back stay in the officer's inventory and are remembered | They are taken back within a minute, once the officer is online and not on a mission |
| With `requireItem = true`, every way that needs the tablet item is refused ("You need the police tablet in your inventory."); a tablet already open stays open | The item counts again |
| With `Config.Custody.handcuffsItem` set, Detain and Cuff suspect are refused ("You need handcuffs for that.") | They work again |
| Item rewards cannot be claimed ("The inventory is not available right now. Try again later.") | Claims work again. If ox_inventory was not running at the last reward item check, the check runs again by itself |

A reward item you **added** to ox_inventory's `items.lua` is found by the reward item check only after you restart
Crimson-Police too, or save a Rewards setting in Admin UI → **Settings** (that runs the check again).
`CrimsonPoliceAdmin check` runs the start-up check ([8.3](#83-start-up-check-lines)) again at any time.

---

## 9. More documents

| Document | What is in it |
|---|---|
| [docs/OWNER_GUIDE.md](docs/OWNER_GUIDE.md) | Every detail for owners: supervisor permissions, settings, optional extras, how it plays, real suspects, go-live, updates, backups, more console lines and the exports |
| [docs/IN_GAME_CHECKLIST.md](docs/IN_GAME_CHECKLIST.md) | What to check in game, one section per feature |
| [docs/dev/README.md](docs/dev/README.md) | For developers: building the web UI, the checks, and every document and tool in this repository |
| [docs/dev/SPEC.md](docs/dev/SPEC.md) | The product spec: every rule (its Hard rules win over everything) and feature |
| [docs/dev/ARCHITECTURE.md](docs/dev/ARCHITECTURE.md) | The code contracts: module APIs, the run model, the block interface, events and the NUI protocol |
| [docs/dev/INTEGRATIONS.md](docs/dev/INTEGRATIONS.md) | Checked facts about the other resources (qbx_core, sc-*, Renewed-Banking ...) |
| [docs/dev/TESTING.md](docs/dev/TESTING.md), [STYLE.md](docs/dev/STYLE.md), [LOOPS.md](docs/dev/LOOPS.md), [WORKFLOWS.md](docs/dev/WORKFLOWS.md), [FILE_NOTES.md](docs/dev/FILE_NOTES.md) | Tests and checks, the code style, every loop, every workflow, and one line per source file |

**Server owners need nothing from `docs/dev/`.** The resource ships ready to run.
