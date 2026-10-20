# Crimson-Police

A police tablet for **Qbox** FiveM servers. On-duty officers pick a mission type, the server gives them a random
NPC mission, and finished missions pay cash and earn leaderboard points.

**This is the only document you need.** Everything about installing, setting up and running Crimson-Police is on
this page. The small README files inside the folders (`Crimson-Police/`, `items/`, `logos/`, `saves/`, `web/`)
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
   - [4.4 What supervisors may do](#44-what-supervisors-may-do)
   - [4.5 Mission Builder permissions](#45-mission-builder-permissions)
   - [4.6 Things only admins can do](#46-things-only-admins-can-do)
   - [4.7 The server console](#47-the-server-console)
   - [4.8 Common mistakes](#48-common-mistakes)
5. [First things to set in config/config.lua](#5-first-things-to-set-in-configconfiglua)
   - [5.1 Departments and jobs](#51-departments-and-jobs)
   - [5.2 Supervisor grades](#52-supervisor-grades)
   - [5.3 Payouts](#53-payouts)
   - [5.4 Logos](#54-logos)
   - [5.5 The two switches at the top: debug and storage](#55-the-two-switches-at-the-top-debug-and-storage)
   - [5.6 Other settings you may want to change](#56-other-settings-you-may-want-to-change)
   - [5.7 Change any setting in game: the Settings screen](#57-change-any-setting-in-game-the-settings-screen)
   - [5.8 Turn missions and locations on or off](#58-turn-missions-and-locations-on-or-off)
   - [5.9 How hard NPCs fight back](#59-how-hard-npcs-fight-back)
6. [Optional extras](#6-optional-extras)
   - [6.1 The tablet item](#61-the-tablet-item)
   - [6.2 Mission desks](#62-mission-desks)
   - [6.3 Item rewards](#63-item-rewards)
   - [6.4 Profile pictures](#64-profile-pictures)
   - [6.5 Database off: the saves folder](#65-database-off-the-saves-folder)
   - [6.6 Discord webhooks](#66-discord-webhooks)
   - [6.7 Department logos](#67-department-logos)
   - [6.8 Paying from the department's bank account](#68-paying-from-the-departments-bank-account)
   - [6.9 Handcuff and evidence items](#69-handcuff-and-evidence-items)
   - [6.10 Adding a department](#610-adding-a-department)
7. [Settings to check in your other resources](#7-settings-to-check-in-your-other-resources)
8. [All commands and keys](#8-all-commands-and-keys)
   - [8.1 Commands](#81-commands)
   - [8.2 Keys](#82-keys)
   - [8.3 Exports for other scripts](#83-exports-for-other-scripts)
9. [How it plays](#9-how-it-plays)
   - [9.1 The officer's tablet](#91-the-officers-tablet)
   - [9.2 The supervisor's screens](#92-the-supervisors-screens)
   - [9.3 The admin panel](#93-the-admin-panel)
   - [9.4 The missions](#94-the-missions)
   - [9.5 Dispatch: mission calls](#95-dispatch-mission-calls)
   - [9.6 Police actions and custody](#96-police-actions-and-custody)
   - [9.7 Raids](#97-raids)
   - [9.8 XP and levels](#98-xp-and-levels)
   - [9.9 Leaderboards](#99-leaderboards)
   - [9.10 Department challenge and seasons](#910-department-challenge-and-seasons)
   - [9.11 Disputes, flags and suspensions](#911-disputes-flags-and-suspensions)
   - [9.12 Mission Builder](#912-mission-builder)
   - [9.13 Testing tools](#913-testing-tools)
   - [9.14 Rules to tell your officers](#914-rules-to-tell-your-officers)
   - [9.15 Full admin control](#915-full-admin-control)
     - [9.15.1 Officers, points and boards](#9151-officers-points-and-boards)
     - [9.15.2 Missions and the Mission Builder](#9152-missions-and-the-mission-builder)
     - [9.15.3 Live runs, units and anti-farm](#9153-live-runs-units-and-anti-farm)
     - [9.15.4 Payments, item rewards and department money](#9154-payments-item-rewards-and-department-money)
     - [9.15.5 System, departments and settings](#9155-system-departments-and-settings)
10. [Before go-live, updating and backups](#10-before-go-live-updating-and-backups)
    - [10.1 Before go-live checklist](#101-before-go-live-checklist)
    - [10.2 Updating](#102-updating)
    - [10.3 Backups](#103-backups)
11. [Troubleshooting](#11-troubleshooting)
    - [11.1 The tablet does not open](#111-the-tablet-does-not-open)
    - [11.2 Admin UI](#112-admin-ui)
    - [11.3 Start-up check lines](#113-start-up-check-lines)
    - [11.4 Database and saves folder](#114-database-and-saves-folder)
    - [11.5 Config and departments](#115-config-and-departments)
    - [11.6 Missions and the Mission Builder](#116-missions-and-the-mission-builder)
    - [11.7 Payments, webhooks and other lines](#117-payments-webhooks-and-other-lines)
    - [11.8 The screen froze or the controls stopped](#118-the-screen-froze-or-the-controls-stopped)
12. [For developers](#12-for-developers)
    - [Spec revisions](#spec-revisions)

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
- **Police actions**: talk, frisk, search, run plates, cite, arrest and impound, graded against what was really going on.
- **Custody**: arrested NPCs go to a prisoner van, impounded cars to a tow truck, scenes to a coroner van.
- **Units**: officers from any department team up; bigger units get harder missions and more pay.
- **Cross-Department Missions**: a supervisor launches one big mission for every department at once.
- **Cash payouts**: paid into the officer's bank account (with a Renewed-Banking history line), from new money or
  the department's account.
- **XP and levels**: 50 levels plus prestige stars. They are for show only and never change a player's Qbox rank.
- **Leaderboards**: weekly, monthly, season and all-time, ranked by points, arrests, impounds and more.
- **Department challenge and seasons**: departments compete over a season, with a weekly bounty.
- **Profiles**: pictures, bios, commendations and a service record, with moderation.
- **Supervisor tools**: live missions, force recall, review of flagged runs, payouts and a department report.
- **Admin panel**: payouts, seasons, officers, suspensions, audit log, test runs, a config check, and a
  **Settings** screen where an admin changes any setting in game: you never have to edit `config.lua`.
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
  | `sc-police` | Officers can't set a callsign with /callsign, and officers suspended in sc-dispatch are not kept off duty. The start-up check warns you |
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
  [5.5](#55-the-two-switches-at-the-top-debug-and-storage)), Crimson-Police saves to files instead and needs
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
  server.cfg. Leave out any you don't want. See [6.6](#66-discord-webhooks).

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
  your own logo. See [5.1](#51-departments-and-jobs).

Then set the grade where supervisors start (`supervisorGrade`, default `3`). Section
[5.2](#52-supervisor-grades) explains the number. The start-up check (next step) tells you if a job name is wrong
or if the grade means nobody, or everybody, is a supervisor.

**You can also do all of this in game instead of in the file.** Start the server, type `/CrimsonPoliceAdmin`, open
**Settings**, search for `jobs` or `supervisorGrade`, change the value and press **Save**. Department changes work at
once. See [5.7](#57-change-any-setting-in-game-the-settings-screen).

### 3.4 Start the server and read the console

Start (or restart) your server. About 5 seconds after Crimson-Police starts, it checks your setup and prints the
result. On a good install the console shows lines like these (the order can differ):

```
[crimson-police] storage: database off, data saved as files in the saves folder .../resources/Crimson-Police/saves
[crimson-police] first start with the database off: the saves folder .../resources/Crimson-Police/saves is empty, so Crimson-Police starts with no data
[crimson-police] applied migration 001_initial.sql
[crimson-police] applied migration 002_test_def_hash.sql
...
[crimson-police] Crimson-Police saves folder at version 8
[crimson-police] missions loaded: 19 built-in, 0 custom, 0 rejected
[crimson-police] Start-up check: all 18 checks passed. Type CrimsonPoliceAdmin check in the server console to see them
```

- With the database on, the first line reads `storage: MySQL/MariaDB through oxmysql`, the "first start" line is
  not there, and the version line reads `Crimson-Police database at version 8`. On a database made by txAdmin's
  recipe, the first start after this update also prints one `cp_... is utf8mb3_general_ci: switching it to utf8mb4
  (once)` line per table.
- The `applied migration` lines only show on the first start and after an update. A migration is Crimson-Police
  creating or upgrading its own tables.
- The number of checks on the last line depends on your setup.
- The copy you downloaded has `Config.Debug = true`, so you also see many extra lines that start with
  `[crimson-police:` (for example `[crimson-police:admin] /CrimsonPoliceAdmin registered`). They are normal and help
  while you test. Before go-live, set `Config.Debug = false` in `config/config.lua` for a quiet console (see
  [5.5](#55-the-two-switches-at-the-top-debug-and-storage)).

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
check runs again after every change ([5.7](#57-change-any-setting-in-game-the-settings-screen)). To see every check
again at any time, type this in the server console:

```
CrimsonPoliceAdmin check
```

Section [11](#11-troubleshooting) lists every message and what to do.

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

Players can also bind keys for the tablet. See [8.2](#82-keys).

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
- Nobody, admins included, may approve, void or answer a dispute about a run they took part in.
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

- The easiest: ask the player to type `/CrimsonPoliceAdmin` once. They get "Only admins can open the Admin UI.",
  and your server console gets one line with the exact line to paste, their ID included:
  `John (server id 3) typed /CrimsonPoliceAdmin but is not an admin. To make them one, add this line to server.cfg and restart: add_ace identifier.fivem:1234567 crimsonpolice.admin allow`
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

### 4.4 What supervisors may do

Set in `Config.Permissions.supervisor` in `config/config.lua`, or switch them in game in Admin UI → **Permissions**
(each switch saves at once). `true` = supervisors may do it. `false` = the button is hidden and the server refuses
it. Admins can always do all of these.

| Setting | Default | What it allows | Limits |
|---|---|---|---|
| `setTypePayout` | `true` | Change a mission type's payout | 50–200% of the config payout, once per 30 minutes per type, a reason is required, never a type an admin has set |
| `launchCrossDept` | `true` | Launch, start now, relaunch and cancel Cross-Department Missions; remove a joiner before the start | At most one launch every 30 minutes, server-wide |
| `forceRecall` | `true` | End one officer's run with no penalty | Runs of their own department; never a run they are on |
| `reviewFlagged` | `true` | Approve or void flagged runs | Their department; never their own run |
| `handleDisputes` | `true` | Answer disputes about flagged or voided runs | Their department; never their own run |
| `builderEdit` | `true` | Mission Builder: create, edit, record routes and test | Their own missions |
| `builderPublish` | `true` | Publish their own drafts (a test is optional) | Their own missions |
| `builderArchive` | `true` | Archive or restore their own missions | Their own missions |
| `builderEditAny` | `false` | Also edit, publish and archive other people's missions | All custom missions |
| `builderRollback` | `false` | Roll a custom mission back to its previous version | Their own, or any with `builderEditAny` |
| `breakEditLock` | `false` | Unlock a mission someone else is editing | Any mission |
| `missionCalls` | `true` | View, withdraw, page and create mission calls | 2 minutes between calls they create; never paging their own unit |
| `issueCommendation` | `true` | Commend officers, and revoke a commendation | Their department only, 3 a day, never themselves |
| `reviewProfiles` | `true` | Approve or reject pictures and bios, clear a bio | Their department; never their own profile |

Supervisors can always see the Mission List, Live Missions and the Department Report of their own department. The
other screens hide when their switch is `false`: **Cross-Department Mission** (`launchCrossDept`), **Payouts**
(`setTypePayout`), **Mission Builder** (`builderEdit`) and **Review Queue** (when `reviewFlagged` and
`handleDisputes` are both `false`).

Related settings: `Config.Payouts.supervisorRange` (`{ 0.5, 2.0 }` = 50–200%), `Config.Payouts.supervisorCooldown`
(`1800` seconds), `Config.Commendations.crossDepartment` (`true` lets supervisors commend other departments),
`Config.Commendations.perSupervisorPerDay` (`3`).

### 4.5 Mission Builder permissions

- `Config.Builder.enabled = false` turns the Mission Builder off for everyone.
- Admins have every builder right. Supervisors have the six Mission Builder switches above, from `builderEdit` to
  `breakEditLock`.
- "Own mission" means a mission the supervisor made.
- A supervisor can't test a draft while a Cross-Department Mission is running. An admin can.
- **Testing is optional.** Anyone allowed to publish can publish a draft without testing it (the tablet asks
  "Publish without testing?" once). To make supervisors pass a test first, switch on
  `Config.Builder.requireTestToPublish` (Admin UI → **Settings**, section Mission builder). Admins never need one.
- **Mission items are for admins only.** A supervisor can't put any item in a custom mission: saving, checking,
  testing or publishing one with an item says "<item> can't be a mission item.", and Details → **Mission items** is
  locked with a sentence saying why. An officer can use or sell a mission item before the run takes it back, so items
  a supervisor wrote would be made out of nothing. To let supervisors add items too, set
  `Config.Builder.supervisorItems = true` (Admin UI → **Settings**, section Mission builder). Money items (`cash`,
  `money`, `black_money`), weapons, ammo, armour and bandages are never mission items, for anyone.
- A run hands out a custom mission's items only when an admin (or the console) published that version, or it was
  edited in code. A version a supervisor published, or an older one with no record of who published it, hands out
  none and says so once in Admin UI → **System** → **Problems** ("items skipped: saved by a supervisor"). To give it
  back its items, an admin opens it in the Mission Builder and publishes it again.

### 4.6 Things only admins can do

**What admins can do now.** Everything below is a button in `/CrimsonPoliceAdmin`, needs a reason, and goes into the
audit log. [9.15](#915-full-admin-control) explains each one.

- **Officers**: add or take away points, check and fix XP, void or restore runs in bulk (every batch has **Undo**),
  retire and unretire an officer, move a record to a player's new character, grant or revoke badges, fix a streak,
  mark a goal done, reset a picture or bio, suspend until an exact time, post a staff notice on Home
  ([9.15.1](#9151-officers-points-and-boards)).
- **Boards and seasons**: rank by any number, look at past weeks and months, recount a week and post it again,
  rename a season, plan its end, end it, reopen it within 24 hours, pick next week's bounty
  ([9.15.1](#9151-officers-points-and-boards)).
- **Missions**: edit **any built-in mission** in the Mission Builder (it stays under the same mission id, and
  **Reset to original** brings the shipped one back), quick-edit cooldowns, timers, NPCs, cars and weapons, delete
  and bring back, change owner, import and copy as Lua, see mission, operation and dispatch history and stats, and
  switch any mission or location on or off ([9.15.2](#9152-missions-and-the-mission-builder),
  [5.8](#58-turn-missions-and-locations-on-or-off)). No mission ever needs a test.
- **Live runs**: recall, end or add time to any run, end someone else's test, remove a member from a unit or disband
  it; per officer clear cooldowns, allow more runs today or another boss attempt; change today's Type of the Day
  ([9.15.3](#9153-live-runs-units-and-anti-farm)).
- **Money**: the Payments ledger with totals and a CSV export, **Pay now**, resolve a payment stuck in "paying",
  cancel or forfeit a payment, adjust every payout at once, each department's funds. The tools that move money
  outside the normal flow are built but **ship off**; you switch one on in Settings by typing `ENABLE`
  ([9.15.4](#9154-payments-item-rewards-and-department-money)).
- **System**: add, edit, turn off and delete departments, place desks, upload logos, copy and switch the storage,
  back up and restore, see which webhooks are on, read recent problems, check the other resources, run the nightly
  clean-up now, and revert or export your settings ([9.15.5](#9155-system-departments-and-settings)).

**What stays out of the tablet, on purpose**: who is an admin (server.cfg, and `Config.AdminAce` /
`Config.QboxAdmins` in config.lua, shown locked in Settings), Discord webhook links (server.cfg only, never shown in
game), and restarting Crimson-Police (txAdmin or the server console; Crimson-Police never restarts itself).

These are always admin only. Setting one of them to `true` in `Config.Permissions.supervisor` does nothing.

- Open the Admin UI.
- Change settings in game (Admin UI → **Settings**), and turn missions and locations on or off.
- Set or clear the payout of **one** mission, and clear any admin-set payout.
- Give points by hand (manual award).
- Answer disputes about **failed** runs.
- Void any run.
- Start and end seasons, and override the weekly bounty.
- Suspend and unsuspend officers.
- Adjust points (add or take away), void and restore runs in bulk, retire officers, move a record, fix XP, grant
  and revoke badges, and the other officer, board and season tools of [9.15.1](#9151-officers-points-and-boards).
- Reload mission files.
- Start test runs.

### 4.7 The server console

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
    `ensure Crimson-Police` afterwards ([11.4](#114-database-and-saves-folder)).
  - `set cp_settings_safe 1` in server.cfg starts Crimson-Police once with config.lua only: the settings changed in
    game are ignored, not deleted. Remove the line (or set it to `0`) and restart to use them again.
- Section [8.1](#81-commands) lists every command.

### 4.8 Common mistakes

- Don't add `add_ace group.admin command.CrimsonPoliceAdmin allow`. It is not needed: the command checks
  `crimsonpolice.admin` itself.
- **Never** add `add_ace builtin.everyone crimsonpolice.admin allow`. It makes every player an admin.
- Only add `add_ace group.mod crimsonpolice.admin allow` if you really want moderators to change payouts, suspend
  officers and void runs.
- Don't put someone in `group.admin` just for the tablet. Use the tablet-only line in [4.2](#42-admins) instead:
  `group.admin` can run every server command.
- `supervisorGrade` is a grade **number**, not a grade name.

---

## 5. First things to set in config/config.lua

Every setting lives in `Crimson-Police/config/config.lua`. Each line has a short note. **You never have to edit
this file:** every setting below can be changed in game by an admin in Admin UI → **Settings**
([5.7](#57-change-any-setting-in-game-the-settings-screen)), with the same note shown next to it. If you do edit the
file, restart Crimson-Police after a change (`restart Crimson-Police` in the console). If `config.lua` has a typing
mistake, a red line says so when it starts (see [11.5](#115-config-and-departments)).

### 5.1 Departments and jobs

Each block in `Config.Departments` is one department. The shipped ones are `sast` and `fib`.

```lua
-- shortened: config/config.lua has the whole block
Config.Departments = {
    sast = {
        label = 'San Andreas State Troopers',  -- shown in the tablet header
        short = 'SAST',                        -- tag on boards, units and badges
        jobs = { 'sast' },                     -- Qbox job names
        supervisorGrade = 3,                   -- Qbox grade number: this grade and up are supervisors
        societyAccount = 'sast',               -- only used when Config.Cash.source = 'society'
        theme = { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235', ... },
        logo = { file = 'sast.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
    },
    fib = { ... },
}
```

- `jobs`: the Qbox job names whose players belong to this department. They must exist in your Qbox jobs file
  (see [3.3](#33-check-your-police-jobs)). A job may only be in one department.
- `label` and `short`: the name and tag players see.
- `theme`: the tablet colours, as 6-digit hex colours like `#1f4e8c`. `personalAccents` inside `theme` lists the
  accent colours officers may pick for their own tablet (some unlock at a level).
- `logo`: see [5.4](#54-logos).
- To add a department (BCSO, for example), see [6.10](#610-adding-a-department).

### 5.2 Supervisor grades

Set `supervisorGrade` in each department to the grade number where supervisors start. Section
[4.3](#43-supervisors) shows how to find the number. The shipped value is `3` in both departments.

### 5.3 Payouts

The shipped amounts are starting values. Set them to fit your economy.

```lua
Config.MissionTypes = {
    patrol = { label = 'Patrol', points = 60, payout = 250, dailyLimit = nil },
    training = { label = 'Training', points = 100, payout = 350, dailyLimit = nil },
    investigation = { label = 'Investigation', points = 160, payout = 600, dailyLimit = nil },
    tactical = { label = 'Tactical', points = 200, payout = 800, dailyLimit = nil },
}
```

- `payout`: the cash each officer gets for a finished mission of that type, before the team-size bonus
  (up to ×1.75 for the biggest teams).
- `points`: leaderboard points. Only an admin can change them: here, or in Admin UI → **Settings** (every change is
  in the audit log). Officers and supervisors never can.
- `dailyLimit`: finished missions of that type per officer per day. `nil` = no limit.
- The Weekly Boss pays its own amount: `payout = 2500` in `Config.Events.weeklyBoss`.
- `Config.Cash`: `account = 'bank'` or `'cash'`; `source = 'server'` (new money) or `'society'` (the department's
  bank account, see [6.8](#68-paying-from-the-departments-bank-account)); `minPayout` and `maxPayout` limit every
  payout set in game (0 to 25,000); `dailyCap` = most cash per officer per day (0 = no cap).
- Admins can also change payouts in game (Admin UI → **Payouts**, or `/CrimsonPoliceAdmin payout type patrol 300
  New economy`). A payout set in game wins over `config.lua`. An admin can go back to the `config.lua` value with
  `/CrimsonPoliceAdmin payout type patrol clear Back to config`. **Unlock for supervisors** and **Adjust all** are in
  [9.15.4](#9154-payments-item-rewards-and-department-money).
- The other `Config.Cash` keys are the admin money tools (`allowPayAgain`, `allowUnfundedRetry`, `allowCapTopUp`,
  `restoreForfeited`, `allowClawback`, `allowManualCash`, `allowAddFunds`, all `false`), their limits (`addFundsMax`,
  `manualDailyLimit`) and `lowBalanceWarn`. See [9.15.4](#9154-payments-item-rewards-and-department-money).

### 5.4 Logos

Each department shows its logo in the tablet header and faintly behind every screen. The shipped `sast.png` and
`fib.png` in `Crimson-Police/logos/` are placeholders. Put your own file there with the same name, or change
`logo.file`, then restart Crimson-Police. Section [6.7](#67-department-logos) has the details.

### 5.5 The two switches at the top: debug and storage

The top of `config/config.lua` has two switches. **In the copy you downloaded, both are set like this:**

```lua
Config.Debug = true              -- true = each module prints tagged debug lines

Config.Database = {
    enabled = false,
    folder = 'saves',
}
```

- **Debug is on for testing.** `Config.Debug = true` prints many extra `[crimson-police:…]` lines in the console.
  Leave it on while you set up and test: the extra lines help when something goes wrong. **Before go-live**, set
  `Config.Debug = false` and restart Crimson-Police for a quiet console.
- **The database is off.** `Config.Database.enabled = false` saves everything as files in `Crimson-Police/saves`,
  with no database tables. Nothing to set up. Section [6.5](#65-database-off-the-saves-folder) explains the folder.
- **To turn the database on** and keep everything in your MySQL/MariaDB database instead:
  1. Check that oxmysql connects. Qbox already uses it, through the `set mysql_connection_string` line in your
     `server.cfg`, so on a working Qbox server there is nothing to add.
  2. Set `enabled = true` in `Config.Database`.
  3. Restart Crimson-Police. It makes its own tables on the first start (there is no SQL to import). The console
     then says `storage: MySQL/MariaDB through oxmysql`.
- Both work the same for players. Switching does not move your data by itself: on a server that already has data,
  read "Switching on a server that already has data" in [6.5](#65-database-off-the-saves-folder) first. The copy to
  the database switches its tables to `utf8mb4` too, so on a database made by txAdmin's recipe the names and reasons
  with emoji in your saves folder come along.

### 5.6 Other settings you may want to change

Everything else works as shipped. These are the ones owners change most:

| Setting | What it does |
|---|---|
| `Config.Format.currency` | The money symbol (`'$'`) |
| `Config.Locale` | Leave it `'en'`: English is the only language shipped |
| `Config.Tablet.keybind`, `dispatchKey`, `readyKey`, `contactKey` | Default keys for new players (`''` = none). See [8.2](#82-keys) |
| `Config.Tablet.access` | Which ways open the tablet: `command`, `keybind`, `item`, `desk`, and `requireItem` |
| `Config.DisabledMissions` | Missions to turn off, e.g. `{ 'prison_break' }`. Easier: the on/off switches in Admin UI → **Missions** ([5.8](#58-turn-missions-and-locations-on-or-off)) |
| `Config.DisabledLocations` | Single locations to turn off, by mission: `{ prison_break = { 'North gate' } }`. Also switched in Admin UI → **Missions** |
| `Config.MissionTweaks` | Change a built-in mission's cooldown or time limits, switch off some of its locations, or change its NPC models, cars or weapons, without editing its file |
| `Config.Limits` | `maxCompletionsHour = 8` and `maxCompletionsDay = 0` (0 = no cap) finished missions per officer; `maxConcurrentRuns = 12` and `maxConcurrentTactical = 4` missions at once, server-wide |
| `Config.Spawning` | Where a mission's people may appear (the spawn director): never closer than `minDistance` (40 m) to any officer, `minDistanceIndoor` (15 m) inside a building; never behind your officers (more than `behindAngle`, 110 degrees, off an officer's line to the scene, whichever side he came in from, counted for officers within `activateRange`); one wave always from one side (a `maxSpread` slice of 150 degrees, so never all around them); and an objective's people only once an officer is within `activateRange` (150 m). A wave that finds too few such points spawns what it can and the rest later (as your officers move or hostiles fall), waits up to `waveDelayMax` (20 s), then may use points down to `hardMin` (20 m) away, never closer. If a wave still cannot be placed `leaveOutAfter` (45 s) after it began waiting and nobody of the fight is left standing, the hostiles it could not place are left out so the fight can end (never before the fight's first hostile appeared; 0 = wait for ever). Used by every shootout: Gang Shootout and the Weekly Boss, and at the indoor distance Hostage Rescue and the raids' fights. `log` prints a console line for each point it skips, by its name in the mission file (`spawns[7] skipped: 2 m from <officer>`, with `Config.Debug`) and a warning when a wave had to come closer or left someone out. `stageAhead` (on) lets a mission place the next objective's people ahead of time, while your officers are still busy with the one before it, so they are already in place when it starts instead of popping up around the officers the moment it does (the raids use it; off = everyone appears when their objective starts). `stageWakeRange` (12 m): a raid's crew waits calm and unarmed before the breach and wakes, armed, when the fight starts, or earlier when one of them is hurt or killed or an officer comes this close to one of them (officers at the breach entries, nearer to an entry than to him, do not count; 0 = only a hurt one wakes them). `associatesAtKnock` (on): Warrant Service's armed associates come out only when an officer knocks, 15 m or more from every officer, out of sight first and never behind the officer at the door, instead of waiting beside the door from the start (off = they wait at their points from the start, as before). Every associate and every scattering suspect (Prison Break, the raids' cooks and runners) gets a point of his own, never on another person, a body or a car; a list with too few points is said once in System → Problems and the others come out there one after another. `sceneOutside` (10 m): a field contact scene (Suspicious Activity's car and people, all at once) and each parked car of Parking Patrol appear once an officer is within `activateRange` of it while every officer is further than the mission's approach distance (25 m) plus this from it, so they are there before you are on top of them; an officer standing closer keeps it waiting (`hardMin` after `waveDelayMax`), and `sceneWaitMax` (45 s; 0 = for ever) after it began waiting it appears anyway with one console warning naming the mission and the place (move that start further out). `hostagesAt` (`'objective'`): Hostage Rescue's hostages appear when their own objective starts (after the fight), on their points `minDistanceIndoor` (15 m) or more from every officer; an officer standing closer keeps them waiting, and `hostagesWaitMax` (10 s; 0 = until the officers step back) after that they appear on their points anyway with one console warning (they are tied up and unarmed, and the rescue cannot go on without them); `'runStart'` = at run start, before the fight, as before. Manhunt: nothing appears when the search starts; each fugitive appears on his hiding spot once an officer is within `activateRange` of it and every officer is `minDistance` (40 m) or more from it, never closer (an officer standing closer keeps him waiting, and after `waveDelayMax` he hides on another free hiding spot in the circle instead, one console line), and each clue once an officer is within `activateRange` of it, 40 m or more from every officer or closer where no officer can see it (`hardMin` in sight after `waveDelayMax`); the circle still shrinks towards the fugitive's hiding spot before he has appeared. `contactRing` (25-40 m): a parked car's returning driver and a stolen car's thief appear this far from the car, on a footpath point the game of the officer at the car picks in front of him and out of his sight first (no answer within `losTimeoutMs`: round the car, never closer than 25 m to any officer), wait to be put on the ground, then walk up to the car (off: 14 m and 30 m round the car, as before). `vehicleLift` (0.5 m, 0-1.5): a car made on a point of the mission's road itself (Traffic Enforcement's violator, a race loop's waypoint, Armored Truck Escort's truck and ambush cars) is lifted this far over the road there, so it never starts inside the road surface (0 = on the road's own height; a mission's own pursuit car points are used as written). Armored Truck Escort's truck is never made inside a car parked on the start or on an officer standing there: it waits for the start to be clear (the officers are told so on the HUD) and after `waveDelayMax` takes the first free spot further along the route. `ambushAheadOnly` (on): an Armored Truck Escort ambush car never appears on another vehicle, next to the truck (within `minDistance`) or behind it, and like every car it never appears within `minDistance` of an officer (a lead car driving ahead of the truck included): its slot slides further along the route, ahead of the truck (off = the ambush point's own slots only, also once the truck is past it, as before). `secondViolatorUpstream` (200 m, 0-400): a violator that follows another one on the same road (Traffic Enforcement's second violator) appears this far up the road from the officer furthest up it (officers within 100 m of the road count), so it drives towards your officers wherever they worked the first stop, and its blip shows once it has passed where they stood (0 = at the first violator's point, as before). Every pursuit car's point also goes through the director (never within `minDistance` of an officer: it waits or takes its next slot further back, `hardMin` after `waveDelayMax`) and the placer. `preferHidden` (on): of the points a wave may use, the ones your officers cannot see (behind a building, a container or a vehicle, as the nearest officers' own games check it: a line of sight from the officer's head and his camera to where the person would stand) are used first, so hostiles appear out of sight instead of in the open in front of you; seen points are still used when there are not enough hidden ones, and a fight with points on two sides comes from the side with more hidden points; a Manhunt clue closer than `minDistance` appears only where those games say no officer can see it (off: such a clue waits until the officers step back). `losTimeoutMs` (1500 ms, 100-5000): how long the server waits for that answer; a game that does not answer in time (or still owes an earlier answer) makes every point count as seen, the distance rules still apply (console: `wave 1 (spawns): 3 of 9 points out of the officers' sight, used first` / `no usable answer from <officer> within 1500 ms`). `ground` (`pedAbove` -0.3 to 1.6 m, `vehicleAbove` -0.2 to 1.5 m, `propAbove` -0.1 to 0.5 m, `snapWithin` 3 m), `collisionTimeoutMs` (6000 ms) and `interiorTimeoutMs` (5000 ms): how a point is judged against the ground under it (how far over the ground a person's, a vehicle's or an object's point may be; how far a point may be moved onto the ground; how long a game waits for the ground and for the inside of a building to load), for the spawn point check (see [9.13](#913-testing-tools)) and the placer. `place` (on): every new person, vehicle and object of a mission waits frozen where it appears until the game of an officer of that run near it has checked the ground there (by those ranges) and put it on the ground at that spot: a person standing on it, a vehicle on its wheels, an object on it; it is never moved to another spot. A point under the ground, floating, in water, in a wall or inside a building that never loaded stays frozen and is reported to the server instead, and the server moves it to another point the mission may use there (a shootout's other spawn points, still away from your officers), at most `retries` (2) times; after that, or with no other point, it is let go where it is, as before, with one console warning naming the point (`run <id>: ped <model> at x y z is underground (ground 31.40); used spawns[4] (70.00 170.00 31.00) instead`), so you can fix it in the mission file. `placeTimeoutMs` (8000 ms, 1000-60000): how long one waits for an officer's game, counted only while an officer is within `activateRange` of it (nobody near: it waits frozen); then `onTimeout`: `'unfreeze'` (default) lets it go where it stands, as before, `'delete'` removes it and the mission counts it as gone (one warning either way). Off = everyone appears on the file's points as before, nothing is frozen. `enabled = false` turns all of it off: hostiles appear on the file's points as before (only the spawn point check, which you start yourself, still judges points by `ground`) |
| `Config.NpcDifficulty.preset` | `'easy'`, `'normal'`, `'hard'` or `'custom'`. Changes how NPCs fight, never the pay |
| `Config.NpcCombat` | How hard armed NPCs fight back: no automatic weapons, an accuracy cap, single shots, half damage, no headshot one-shots. See [5.9](#59-how-hard-npcs-fight-back) |
| `Config.Flee` | How long a suspect who runs from your officers keeps running: the server times every runner on foot (time in a car does not count), who sprints for `sprintSeconds` (10), jogs for `jogSeconds` (12), walks for `walkSeconds` (8) and is then worn out. Each suspect lasts up to `jitter` (25 %) longer or shorter, `Config.NpcDifficulty`'s `fleeMult` stretches it (`'hard'`: 20 % longer), a runner no officer comes within `recoverRange` (60 m) of for `recoverSeconds` (20 s) sprints again, and `armedTire = false` keeps armed suspects fresh. A tired runner visibly slows down: at most a jog, then a walk, at `jogRate` (0.95) / `walkRate` (0.85) of the normal speed, and with `windedClipset` he jogs, then walks winded. Once worn out he gives up as soon as an officer is within `giveUpRange` (30 m): `exhausted = 'surrender'` he kneels, `'handsUp'` he stands with his hands up (Cuff suspect either way), `'walk'` he walks on and never gives up on his own. `enabled = false` turns it off. `nearestRoute` (on): a runner, cook or inmate who scatters flees along the escape route that starts nearest where he appears, so nobody runs back across the site past your officers (`false`: the routes take turns) |
| `Config.Markers` | The objective on your officers' map: one blip for the objective they are on (for a fight or a search area, a circle and its centre) and one GPS line to it (`route`, in `routeColour`: 5 = yellow), off within `routeOffWithin` (40 m) of it and inside a circle. An officer still driving to the start, or with a waypoint of his own, keeps that as his only line. A suspect or car too far away for his game still shows where the server says (`farTargets`); objective blips show at the radar edge (`shortRange = false`), flash for `flashSeconds` (5 s) when new and show their distance in the map legend (`category = 2`); `areaAlpha` (80) is how solid the circles are, and a start at least `startCircleMin` (200 m) wide shows as a circle. `radioSilence` (`'area'`) is what Radio Silence hides: `'area'` keeps a circle or the one objective blip without a GPS line and without blips on people and cars, `'none'` hides every objective blip, `'full'` nothing. `kinds` sets each kind of blip's sprite, colour and size (yellow = go here, red = enemy, orange = fleeing, blue = friendly, green = safe point). `enabled = false` turns it off |
| `Config.MissionCalls` | Tablet mission calls: `enabled`, how often (`spawnEvery`), how many open at once (`maxOpen`) |
| `Config.CrossDept.enabled` | Cross-Department Missions on or off |
| `Config.Units.invitePolicy` | `'anyone'` in a unit may invite, or only the `'leader'` |
| `Config.Goals` | Daily and weekly goals and their points |
| `Config.Events` | Type of the Day, mission modifiers, and the Weekly Boss (`weeklyBoss.days`, `points`, `payout`) |
| `Config.Challenge` | The department challenge: `enabled`, `scoring` (`'average'`, `'total'` or `'top10'`), weekly bounty |
| `Config.Leaderboard.weekStartsOn` | The day the week starts (`'monday'`) |
| `Config.Time.resetHour` | The hour (0–23, server time) of the daily reset |
| `Config.XPLevels` | Names and colours of the XP level bands (for show only) |
| `Config.Profile` | Bios, banned words, picture presets and picture links (see [6.4](#64-profile-pictures)) |
| `Config.Commendations` | Commendation kinds and limits; `announce = true` posts them to the board webhook |
| `Config.Rewards` | Item rewards, off by default (see [6.3](#63-item-rewards)) |
| `Config.Disputes.windowHours` | How long officers have to dispute a run (48 hours) |
| `Config.AntiCheat` | Flag limits, and the automatic suspension: 3 voided runs in 30 days = 7 days |
| `Config.Builder` | Mission Builder on or off, what builders may pick, `noBuildZones`, `requireTestToPublish` (`false` = testing is optional, as shipped), `supervisorItems` (`false` = only admins put items in a custom mission, as shipped; [4.5](#45-mission-builder-permissions)), and `spawnMargin` (40 m, 0-150): a custom mission's armed NPCs (a shootout and its boss, ambush and pursuit cars, warrant associates) must spawn outside the start circle plus this, e.g. 100 m from a 60 m start, so a fight never appears around your officers as they arrive (hostages and suspects keep `minSpawnFromStart`, 30 m) |
| `Config.Testing` | Admin test mode: `enabled`, `maxTesters`, `allowTeleport`, `debugOverlay`, and `spawnCheck` (the spawn point check: `enabled`, `sceneTimeoutMs` 8000, `moveWithin` 150 m, `routes = false` checks no route points, `teleport = true` the Teleport here button next to a result) |
| `Config.Retention` | Clean-up of old data: runs archived after 12 months, audit rows deleted after 180 days, mission calls after 90 days (0 = keep) |
| `Config.Downed.dropOffs` | Where a downed officer is taken when no EMS is on duty |
| `Config.Custody.tow.enabled` | `false` makes impounded cars fade out instead of leaving on a tow truck |
| `Config.Custody.serviceClearance` | `30.0` m: a prisoner van, tow truck or coroner van never appears or is put down closer than this to any player |

`config/blocks.lua` holds the Mission Builder's ranges and defaults, and `config/banned_words.txt` the default list
of words refused in bios (one per line). Read that list and change it for your community.

### 5.7 Change any setting in game: the Settings screen

Admins can change **every** setting of `config/config.lua` and `config/blocks.lua` in game, with no file to edit and
no restart to do by hand. Type `/CrimsonPoliceAdmin` and open **Settings**.

- **Every setting is listed**, grouped like the file (Tablet and commands, Departments, Mission types, Cash, ... and
  the Mission Builder ranges of `blocks.lua`), with the note from `config.lua` as its description. Use the search box
  (a name, a path like `Tablet.deskDistance`, or a word of the note), or the **Changed** and **After restart**
  filters.
- **Each setting has the right control**: a switch for on/off, a number box with its allowed range, a text box, a
  colour picker, a list editor, and a text box for tables (written as JSON, for example the scaling rows).
- **Save** checks the value on the server and uses it at once. The value next to it, `config.lua: ...`, is the
  file's value. A setting you changed shows a **Changed** badge, and **Reset** puts the file's value back.
  **Reset all** puts every setting back.
- **Changes are kept.** They are saved in your database (or the saves folder with the database off) and survive
  restarts and updates. A change made in game wins over `config.lua`. You can still edit `config.lua`: a setting you
  never changed in game keeps following the file.
- **A few settings are read only when Crimson-Police starts** (default keys, mission desks, the language, the hour
  of the daily reset and the first day of the week). They have an **After restart** badge: the
  screen saves the change and shows "Running now: ... · after a restart: ...". Restart it from txAdmin or type
  `restart Crimson-Police` in the server console when no mission is running.

- **Changes to the missions' rules** (the Mission Builder ranges, mission tweaks, types, bonuses) reload the
  missions by themselves, like **Missions → Reload**. Runs already going keep what they started with.
- **Config health runs again after every change** and shows its result at the top, so a mistake shows at once.
- **The History tab** lists every change made in game: who, when, which setting, old and new value. Every change is
  also in the **Audit Log** (and the audit Discord webhook).
- **What it refuses**: a value of the wrong kind (text for a number, a list for a switch), a number outside its range,
  a colour that is not `#rrggbb`, an option that does not exist, and a Mission Builder export folder outside
  `missions/custom/`. The message says why.
- **A few settings stay in the file** and show as locked on the screen: `Config.Database` (database on or off,
  and the saves folder), because the settings themselves are saved there; `Config.AdminAce` and
  `Config.QboxAdmins`, which decide who is an admin, so no one can hand admin to every player or lock every admin out
  from the tablet; the tablet title and the two command names (another script with the same command would lock you
  out of the Admin UI); the call-id prefixes that match sc-npcpolice and sc-dispatch; and a bonus's `each`, `block`
  and `engineOnly`, which only describe what the code does. Change them in `config.lua` and restart.
- **Money tools ship off.** The switches `Config.Cash.allowUnfundedRetry`, `allowCapTopUp`, `allowPayAgain`,
  `restoreForfeited`, `allowAddFunds`, `allowClawback`, `allowManualCash` and `Config.Rewards.allowTakeBack` turn on
  admin tools that move money outside the normal pay flow. To turn one on you type **ENABLE** in the box the screen
  shows; the change is in the audit log and the audit Discord webhook. Turn them on only after trying them on a test
  server with Renewed-Banking.
- **Point values** (mission type points, bonus values, scoring rules, Type of the Day and the like) are marked. A
  change counts for runs that end after it; past runs keep their points. Each change also posts a notice to the flags
  webhook. A bonus's kind (points or a share of the type's points) can only change together with its value.
- **Names**: `Config.Labels` gives your own English names to offences, commendation kinds, badges, bonuses and
  penalties, for example `['custody.offence.loitering'] = 'Hanging around'`. Only the name changes, never what it
  does.
- **History**: every change also keeps the full old and new value, so a change can be looked at (and undone) later.
- If a saved setting is no longer allowed (for example after an update changed a setting's form), Crimson-Police
  ignores it with one console line, uses the `config.lua` value, and the Settings screen marks it so you can change
  or reset it.

Admins only: supervisors and officers never see this screen, and the server checks every change again.

### 5.8 Turn missions and locations on or off

Admin UI → **Missions** has a switch next to every mission, built-in and custom:

- **Off**: the mission is never drawn again (Mission Board, mission calls, Cross-Department Missions, the Weekly Boss).
  A run of it that is already going finishes normally.
- **Locations**: the **n/m locations** button lists every location of the mission with its own switch. A location
  turned off is never drawn. With every location off, the mission is never drawn.
- **Reset to default** in that window puts the mission's switches back to `config.lua`'s.
- The switches work at once, are saved like every other setting (database or saves folder), and are in the audit log.
  They are `Config.DisabledMissions` and `Config.DisabledLocations` in `config.lua`.
- Nothing needs a test before it is used: a mission you just switched on is drawn at once.

### 5.9 How hard NPCs fight back

`Config.NpcCombat` decides how dangerous armed mission NPCs are. It changes only the NPCs of Crimson-Police missions
and the officers on their run, and only while the run is live: when the run ends, everything is back to normal. It
never changes points, cash or a mission's stars. Every value can be changed in game in Admin UI → **Settings**
(section *Suspect behaviour*): a new NPC uses the new values, the damage values apply at once.

**For every number here: lower = easier for your officers.**

| Setting | Shipped | What it does |
|---|---|---|
| `enabled` | `true` | `false` turns all of this off: NPCs fight exactly as GTA makes them |
| `weapons` | pistol, combat pistol, heavy pistol, pump shotgun | The only weapons a mission NPC is ever given. An automatic weapon (an SMG, a rifle, a machine gun) is never given, even when you add one here (the Settings screen refuses it) |
| `replace` | micro SMG → pistol, SMG → combat pistol, assault rifle → heavy pistol | What an NPC gets when a mission names a weapon that is not in `weapons` (an older custom mission, a tweak) |
| `fallback` | pistol | ...and when `replace` has nothing for that weapon |
| `ammo` | 60 | Rounds each armed NPC gets |
| `accuracyScale` | 0.7 | NPC accuracy (after the team size and `Config.NpcDifficulty`) is multiplied by this... |
| `accuracyMax` | 18 | ...and never goes above this (0 to 100), bosses and NPCs shooting from cars included. Before this change NPCs reached up to 58, and up to 60 from cars |
| `shootRate` | 60 | How fast NPCs pull the trigger (0 to 1000) |
| `firingPattern` | `'single'` | `'single'` one shot at a time, `'burst'` short bursts, `'delayed'` a pause before each shot, `'default'` GTA picks. NPCs in a car always fire in short bursts, never full auto |
| `abilityMax` | 1 | Combat skill at most: 0 poor, 1 average, 2 professional |
| `noCharge` | `true` | NPCs never charge at officers |
| `aiDamage` | 0.5 | Damage of NPC bullets: 1.0 = normal GTA damage, 0.5 = half |
| `aiMeleeDamage` | 0.5 | The same for NPC punches and melee weapons |
| `officerDefense` | 1.0 (off) | The damage officers on a run take from every weapon, players' shots too (0.5 = half). Leave it at 1.0 unless `aiDamage` alone is not enough |
| `noCriticalHits` | `true` | Officers on a run take no extra headshot damage, from anyone: a headshot hurts like a body shot |
| `cancelLethalHeadshots` | `true` | The server drops a hit from a mission NPC that would kill a healthy officer of its run in one shot (a headshot, a point-blank shotgun blast) |
| `lethalCancelAbove` | 0.75 | How healthy "healthy" is: the officer still has at least this share of his health (0.25 to 1, 0.75 = three quarters). The shot that finishes off an officer who is already hurt always counts, so officers can still go down |

Good to know:

- Each officer's own game applies `aiDamage`, `aiMeleeDamage` and `noCriticalHits` while that officer is on a run,
  and again after a respawn. `aiDamage` softens every NPC bullet his game works out during the run, so an NPC of
  another script next to him, or a mission NPC shooting a hostage, hits softer too.
- `cancelLethalHeadshots` can only catch the hits the server hears about (an NPC that another officer's game moves).
  `noCriticalHits` covers the rest. Neither ever touches a player in Crimson-Arena. It never makes an officer
  unkillable: once he is below `lethalCancelAbove`, the killing shot goes through and he goes down as usual.
- The built-in missions now name pistols and pump shotguns only, and the Mission Builder and Quick edit never offer
  an automatic weapon. A custom mission from an older version that still names one keeps working: one console line
  names it ([11.6](#116-missions-and-the-mission-builder)), and its NPCs carry the `replace` weapon.
- With `enabled = false` nothing is swapped, so the Mission Builder's list (`Config.Builder.allowed.weapons`) is the
  only check again: a custom mission that names a weapon outside it is not loaded (one console line says why) until
  you put the weapon back in that list. Switching `enabled` in Settings reloads the missions at once.
- To feel the difference, run Gang Shootout alone in Admin UI → **Testing**, then change `aiDamage` or
  `accuracyMax` in Settings and run it again.

---

## 6. Optional extras

Each extra is off, or works with no change, until you turn it on.

### 6.1 The tablet item

Without the item, officers open the tablet with `/CrimsonPolice`, a key or a mission desk. The item is an extra way.
Crimson-Police never edits ox_inventory: you copy two things in yourself.

1. Open `Crimson-Police/items/ox_inventory_items.lua`. Copy the `['crimson_police_tablet'] = { ... },` entry into
   `ox_inventory/data/items.lua`, inside its `return { }`. You may change the label, weight or description. Keep
   the item name and the `export = 'Crimson-Police.useTablet'` line.
2. Copy `Crimson-Police/items/crimson_police_tablet.png` into `ox_inventory/web/images/`.
3. In `Crimson-Police/config/config.lua`, set:
   ```lua
   item = 'crimson_police_tablet',   -- inside Config.Tablet
   ```
4. Optional: set `requireItem = true` in `Config.Tablet.access`. Then every way except a mission desk needs the
   item in the inventory, and the tablet closes when the item leaves the inventory.
5. Restart the server (or restart ox_inventory, then Crimson-Police). The start-up check says whether the item and
   its picture were found.

Give the item to officers any way you like, for example in an sc-police armoury or a shop.

### 6.2 Mission desks

A mission desk is a spot at a police station where officers open the tablet with ox_target ("Open Crimson-Police"),
standing at a computer instead of holding a tablet. Walking more than 3 metres away closes it. A desk works even
with `requireItem = true`.

Two desks ship **on**, in `Config.Tablet.desks`. Their positions are guesses near the normal game stations:

```lua
-- inside Config.Tablet (shortened)
desks = {
    {
        label = 'Mission Row PD front desk',
        coords = vec3(441.20, -978.90, 30.69),
        size = vec3(1.2, 0.8, 1.0),
        rotation = 0.0,
        departments = nil,       -- nil = every department; or e.g. { 'sast' }
        prop = false,            -- or a laptop model like 'prop_laptop_01a' that only that player sees
    },
    -- the second one is the 'Sandy Shores office'
},
```

- If your stations are custom interiors (MLOs), stand where you want a desk, read your position with any
  coordinate tool, and put it in `coords`. Add, move or delete desks freely.
- To turn all desks off, set `desk = false` in `Config.Tablet.access`.
- Admin UI → **Departments** lists every desk. The start-up check warns about a desk with bad coordinates.

### 6.3 Item rewards

Finished missions can also give ox_inventory items. **Item rewards are off** (`Config.Rewards.enabled = false`).

**The easy way** (water, burger and sprunk, from ox_inventory's default items, for Patrol, Investigation and
Tactical missions; Training gives nothing until you fill `byType.training`):

```lua
-- shortened: change these two lines in Config.Rewards
Config.Rewards = {
    enabled = true,
    ...
    useExamplePools = true,
```

**Your own items.** Fill `byType` (one entry per mission type) with items that exist in your ox_inventory:

```lua
    byType = {                   -- inside Config.Rewards
        tactical = {
            chance = 0.25,       -- 25% chance per roll
            rolls = 1,           -- rolls per finished mission
            pool = {
                { item = 'water', count = { 1, 2 }, weight = 3, value = 20 },
                { item = 'burger', count = 1, weight = 1, value = 40 },
            },
        },
    },
```

- `count = { 1, 2 }` gives 1 or 2. `weight` makes an item more likely than others in the same pool. `value` is what
  the item is worth to you: it counts toward `dailyValueCap`.
- Other sources, all in `Config.Rewards`: `byMission` (one mission instead of its type), `medals` (EVOC and Pursuit
  Sim medals, e.g. `gold = { item = 'water', count = 1, value = 20 }`), `goals` (`daily` and `weekly`), `levels`
  (e.g. `[10] = { item = 'radio', count = 1, value = 150 }`), `weeklyBoss`, and `season` (`champion`, `top10`).
- Limits per officer per day: `dailyItemCap = 10` items and `dailyValueCap = 2000` of value.
- Weapons, ammo, armour, bandages and money items are never given (the `forbidden` list). A bad or unknown item is
  turned off with a console line.
- An item that doesn't fit the inventory waits in the **Rewards locker** on the officer's Home screen.
- Admin UI → **Leaderboards** → **Item rewards** shows what was given. The start-up check shows whether rewards are
  on and whether every item exists.
- Admins can edit the pools in game (Admin UI → **Settings** → Item rewards, with an item picker), and resolve,
  deliver, cancel or take back a reward: see [9.15.4](#9154-payments-item-rewards-and-department-money). A pool
  changed in game is checked at once: a forbidden or unknown item is never given.

### 6.4 Profile pictures

Officers can always pick a picture from the built-in presets (`Config.Profile.avatarPresets`). Picture **links**
from the web are off. To allow them:

```lua
avatarUrls = {                       -- inside Config.Profile
    enabled = true,
    requireApproval = true,          -- a supervisor of the department or an admin approves each new link
    perDay = 3,
    hosts = { 'r2.fivemanage.com', 'i.imgur.com' },
},
```

- Only links from the listed `hosts` are accepted. Imgur is blocked in the UK and some other regions. Don't add
  Discord links: they expire after a day.
- Supervisors approve pictures in Supervisor UI → **Review Queue** → **Profiles**, admins in Admin UI → **Officers**.
- `Config.Profile.bioRequiresApproval = true` also makes new bios wait for approval.

### 6.5 Database off: the saves folder

With `Config.Database.enabled = false` (as shipped, see [5.5](#55-the-two-switches-at-the-top-debug-and-storage)),
Crimson-Police keeps all its data as files in `Crimson-Police/saves/`, and nothing in your database. Every feature
works the same: runs, points, XP, payouts, boards, seasons, disputes, suspensions, the audit log and custom missions.

- **What is in the folder**: small JSON files, one per table (`officers.json`, `seasons.json` ...). A table with
  more than 500 rows is split (`mission_runs_1.json` holds ids 1–500, `mission_runs_2.json` 501–1000 ...).
  `_tables.json` lists every table. `README.md` is only a note.
- **Keep it** when you update Crimson-Police, and **back it up** like a database. Copy the whole folder while the
  server is stopped.
- **Don't edit** the files while the server runs. You may open and read them. If you edit one with the server
  stopped, it must stay valid JSON. A file that no longer reads stops Crimson-Police on start with its name and
  line, and nothing in the folder is changed.
- **Don't delete** files to save space. A missing file is reported on start, and its rows are gone until you put
  it back from a backup.
- **oxmysql must still run**: it is a required resource, and Crimson-Police reads sc-dispatch's calls through it.
- `folder` may name another folder **inside** the Crimson-Police folder. FXServer only lets a resource write inside
  resource folders.
- `/CrimsonPoliceAdmin storage` shows which storage is in use, the rows of every table and the size of the folder.

**Switching on a server that already has data.** Changing `enabled` moves nothing by itself: Crimson-Police starts
with whatever the other storage holds, which is nothing the first time (the console warns you). Back up first,
then copy, then switch and restart:

- From the database to the saves folder: `CrimsonPoliceAdmin storage copy database-to-files`, then set
  `Config.Database.enabled = false` and restart Crimson-Police.
- From the saves folder to the database: `CrimsonPoliceAdmin storage copy files-to-database` (missing tables are
  made first, and switched to `utf8mb4` on a database made by txAdmin's recipe, one console line each), then set
  `Config.Database.enabled = true` and restart Crimson-Police.

The copy:

- runs in the server console, or in game for an admin (with a slash: `/CrimsonPoliceAdmin storage copy …`);
- copies every Crimson-Police table and keeps every id, including payouts still waiting for an officer to log in
  and the records of your custom missions (their files in `missions/custom/` stay where they are);
- refuses to start while any mission is running ("Active mission runs: 2. Copy when every run has ended.");
- refuses a target that already has data, unless you add `force` at the end, which replaces that data;
- leaves the target empty and the source untouched if it fails, so you can fix the problem and run it again;
- is written to the audit log.

You can also switch first and copy afterwards. Then restart Crimson-Police once more after the copy.

**Which to use.** The saves folder is fine for normal servers. It was tested with 50,000 runs: every board and admin
screen answered in under a quarter of a second, start-up read the folder in about 1.5 seconds, the data took about
75 MB of the server's memory, and the folder about 42 MB. For a very large history (hundreds of thousands of runs,
or `Config.Retention` switched off for years), use the database: the saves folder keeps everything in memory
(about 1.2 KB per run) and reads the whole folder on every start.

**A config.lua from an older version** may have no `Config.Database` block at all. Then add the whole block, not
just one line:

```lua
Config.Database = {
    enabled = false,
    folder = 'saves',
}
```

### 6.6 Discord webhooks

Five optional webhooks, set as convars in `server.cfg` (the block in [3.2](#32-paste-this-into-servercfg)). Leave
out any you don't want.

| Convar | What it posts |
|---|---|
| `cp_webhook_board` | Weekly top 3, season results (and commendations with `Config.Commendations.announce = true`) |
| `cp_webhook_audit` | Payout changes and admin actions |
| `cp_webhook_flags` | Flagged runs, voids and disputes |
| `cp_webhook_builder` | Mission Builder: publish, archive, rollback, edit-lock breaks, file edits and test results |
| `cp_webhook_operations` | Cross-Department Mission launches and results |

- Use `set`, never `setr`. `setr` sends the link to every player's game.
- The link must start with `https://`. Anything else turns that webhook off, and the start-up check says so.
- `CrimsonPoliceAdmin check` in the server console lists which webhooks are on and which are off.
- A new or changed `set` line works after a server restart, or at once if you also type it in txAdmin's Live
  Console.

### 6.7 Department logos

- One file per department in `Crimson-Police/logos/`, named as in `logo.file` of that department (`sast.png` for
  SAST). PNG, WebP or SVG. A square, see-through PNG of at least 1024 × 1024 pixels looks best.
- `sast.png` and `fib.png` are placeholders. Replace them with your own art and restart Crimson-Police. Nothing
  needs to be rebuilt.
- Instead of a file you can use a direct image link: `logo = { url = 'https://…/logo.png', ... }`.
- The other logo settings: `watermark = true` draws the logo behind every screen, `opacity` (0.0 to 0.25) sets how
  faint it is, `size` is its share of the tablet height, `grayscale = true` removes its colour.
- A missing file gives one console line, and that tablet shows no logo until you add the file and restart.

### 6.8 Paying from the department's bank account

By default payouts are new money (`Config.Cash.source = 'server'`). To take them from the department's
Renewed-Banking account instead:

1. Set `source = 'society'` in `Config.Cash`.
2. Check each department's `societyAccount` (`'sast'`, `'fib'`) is the name of its Renewed-Banking account.
3. Put money in those accounts. An account without enough money can't pay: that officer gets no cash for the run,
   and the officer, the department's online supervisors and the console are told ("unfunded").
4. In your Qbox jobs file, give `bankAuth = true` to the grades that may see and fund the account in Renewed-Banking.

Admin UI → **Departments** shows each account's balance and spending (the **Funds** part of each department), and
Admin UI → **Payments** shows every unfunded payment with a **Retry unfunded** button (a switch that ships off). An
account Renewed-Banking does not know shows as an error in the Config health list, and `Config.Cash.lowBalanceWarn`
warns before an account runs dry. See [9.15.4](#9154-payments-item-rewards-and-department-money).

### 6.9 Handcuff and evidence items

Off by default. In `Config.Custody`:

- `handcuffsItem = 'handcuffs'` makes Detain and Cuff suspect need that ox_inventory item (it is checked, not used up).
- `evidenceItem = 'evidence_bag'` gives each officer one per mission, taken back when the mission ends.

Use item names that exist in your ox_inventory.

### 6.10 Adding a department

**In game (no restart):** Admin UI → **Departments** → **Add department**. Give it a key (it can't change later), a
name, a short tag, its Qbox job, the supervisor grade, its society account and colours copied from another
department; upload its logo on the same screen. Its officers can open the tablet at once. A department added in game
can be turned off again, and deleted while it has no history ([9.15.5](#9155-system-departments-and-settings)).
Then do step 4 below for sc-dispatch and sc-police.

**In config.lua** (the old way, still works):

1. In `Config.Departments`, copy the `fib` block (or remove the `--` from the `bcso` example at the end of the
   list), and give it its own key, like `bcso`.
2. Set `label`, `short`, `jobs`, `supervisorGrade`, `societyAccount`, `theme` and `logo`.
3. Put its logo (for example `bcso.png`) in `Crimson-Police/logos/`.
4. Check the job is in sc-dispatch's `Config.Police.AllowedJobs` and sc-police's
   `Config.DispatchIntegration.PoliceJobs` (`bcso` already is in both).
5. Restart Crimson-Police. No code and no SQL changes. A department added in the middle of a season starts at 0.

---

## 7. Settings to check in your other resources

Crimson-Police never edits your other resources. The copies it was built against already have these settings
right, so you only need to check them if you changed them.

| Resource | Setting (in its `config.lua`) | Should be | Why |
|---|---|---|---|
| sc-dispatch | `Config.Integrations.CrimsonArena` | `true` | Hides shots-fired and officer-down calls from missions |
| sc-dispatch | `Config.DispatcherMode.AutoResponding` | `true` | A dispatcher assigning an officer to a real call ends their mission |
| sc-dispatch | `Config.Police.AllowedJobs` | lists every department job (`sast`, `fib`, `bcso` already are) | sc-dispatch treats the job as police (the MDT, real calls, responding) |
| sc-ambulance | `Config.ArenaIntegration.Enabled` | `true` | Hides downed officers on missions from EMS alerts |
| sc-police | `Config.DispatchIntegration.PoliceJobs` | lists every department job (`fib`, `sast`, `police`, `bcso` already are) | sc-police treats the job as police |
| sc-multijob | `set qbx:max_jobs_per_player 5` (a server.cfg line) | as sc-multijob's own config says | Lets players hold several jobs. Only the **active** job counts for Crimson-Police |
| Renewed-Banking | the folder name | exactly `Renewed-Banking` | Payouts use it |
| Crimson-Arena | nothing | | Players in the arena can't use the tablet; its Trailer Park and lobby are already no-build zones |
| sc-npcpolice | nothing | | Its NPC calls never end a mission |

Good to know:

- **sc-police `/imp` and `/depot`**: officers must never use them on mission cars. They use the tablet's
  **Impound** action instead. A participant's `/imp` fails the objective and flags the run; anyone else's ends the
  run as not counted.
- **sc-police evidence**: mission gunfights leave sc-police bullet casings, bullet holes, blood and gunshot residue,
  like any gunfight. That is normal. They are not dispatch alerts.
- **SAST and shots-fired calls outside missions**: sc-dispatch skips shots-fired calls only for on-duty `police`,
  `bcso` and `fib`. To add `sast`, you edit that check in sc-dispatch yourself (`client/main.lua`, in
  `TriggerShotsFiredAlert`). It has nothing to do with missions.
- **Dispatcher Detach**: when a dispatcher detaches an officer from a real call less than 60 seconds after they
  marked themselves responding, Crimson-Police counts a normal abandon (a 5-minute cooldown on that mission type).
  Ask dispatchers to avoid Detach in the first minute.
- **Anti-cheat**: Bomb Disposal plays a harmless explosion (explosion type 2, no damage) from an officer's game. If
  your anti-cheat bans players for client explosions, allow this one for Crimson-Police.
- **Prison**: the Mission Builder can't place anything inside `Config.Builder.noBuildZones`. If your prison
  interior is bigger than the 180-metre `Bolingbroke interior` zone, widen or move it.
- **Server time zone**: daily and weekly resets and the Weekly Boss days use the server machine's clock. Set the
  machine's time zone to your community's.

---

## 8. All commands and keys

### 8.1 Commands

In the server console, type every command **without** the slash.

| Command | Who can use it | What it does |
|---|---|---|
| `/CrimsonPolice` | Officers (on duty, department job) | Opens the tablet (**Esc** or the **X** closes it) |
| `/CrimsonPoliceAdmin` | Admins, in game | Opens the Admin UI. Typed in the server console, it lists the subcommands |
| `CrimsonPoliceState` | Anyone, in the **F8** console | Prints what holds the screen, the NUI focus, the camera and the controls right now, and which part is Crimson-Police's. `CrimsonPoliceState unstick` releases only Crimson-Police's own (see [11.8](#118-the-screen-froze-or-the-controls-stopped)) |
| `/CrimsonPoliceAdmin help` | Admins, console | Lists every subcommand (in game: a one-line list) |
| `/CrimsonPoliceAdmin check` | Admins, console | Runs the start-up check again. The console lists every line; in game you get the counts |
| `/CrimsonPoliceAdmin payout type <type> <amount\|clear> <reason>` | Admins, console | Sets a mission type's payout for good, or clears it back to `config.lua`. Type = `patrol`, `training`, `investigation` or `tactical`. Example: `payout type tactical 1000 Summer event` |
| `/CrimsonPoliceAdmin payout mission <missionId> <amount\|clear> <reason>` | Admins, console | Sets or clears one mission's payout. Example: `payout mission gang_shootout 1200 Harder than the rest` |
| `/CrimsonPoliceAdmin award <citizenid> <points> <reason>` | Admins, console | Gives points by hand (1 to 10,000). The citizenid is the character ID Qbox gives each character: Admin UI → **Officers** shows it under the officer's name |
| `/CrimsonPoliceAdmin season start <name>` | Admins, console | Starts a season (and its department challenge) |
| `/CrimsonPoliceAdmin season end` | Admins, console | Ends the current season |
| `/CrimsonPoliceAdmin suspend <citizenid> <days> [reason]` | Admins, console | Blocks an officer from Crimson-Police for that many days. `0` lifts it |
| `/CrimsonPoliceAdmin reload` | Admins, console | Reloads built-in and custom mission files without a restart |
| `/CrimsonPoliceAdmin test <missionId> [tier] [location\|random]` | Admins, **in game only** | Starts a test run (see [9.13](#913-testing-tools)). Tier = `standard`, `reinforced`, `heavy`, `major`, `critical` or `auto`; location = a number or `random` |
| `/CrimsonPoliceAdmin storage` | Admins, console | Shows the storage in use, the rows of every table and the saves folder size |
| `/CrimsonPoliceAdmin storage copy database-to-files [force]` | Admins, console | Copies everything from the database to the saves folder ([6.5](#65-database-off-the-saves-folder)) |
| `/CrimsonPoliceAdmin storage copy files-to-database [force]` | Admins, console | Copies everything from the saves folder to the database |
| `CrimsonPoliceAdmin storage mode reset` | Console only | Forgets a storage switch made in Admin UI → **System**: the next start uses `Config.Database` from config.lua. `storagemode reset` does the same |
| `CrimsonPoliceAdmin settings` | Console only | Lists every setting changed in game (Admin UI → **Settings**) |
| `CrimsonPoliceAdmin settings reset <path>` | Console only | Puts one setting back to its config.lua value. Example: `settings reset Cash.source` |
| `CrimsonPoliceAdmin settings reset all` | Console only | Puts every setting changed in game back to config.lua |
| `/CrimsonPoliceAdmin missioncall <type> [area]` | Admins, console | Posts a mission call now. Type = `patrol`, `investigation` or `tactical`. Area = `south_ls`, `downtown`, `west_ls`, `vinewood`, `east_ls`, `port`, `senora`, `north`, `west_county` or `county` (the default). Not while a Cross-Department Mission runs; 2 minutes between calls from the same person (the console counts as one) |

"Admins, console" means an admin in game **and** the server console. "Console only" commands are the three ways
back in for when the Admin UI can't open ([4.7](#47-the-server-console)). Mission ids (for `payout mission` and `test`)
are in [9.4](#94-the-missions).

Reasons are required for payout changes (`Config.Payouts.requireReason = true`). Every admin action is written to
the audit log (Admin UI → **Audit Log**).

### 8.2 Keys

Only the test panel has a default key. Players bind the others themselves: **ESC → Settings → Key Bindings →
FiveM**, then look for the Crimson-Police lines.

| Name in the key list | What it does | Default |
|---|---|---|
| Open the Crimson-Police tablet | Same as `/CrimsonPolice` | none (`Config.Tablet.keybind`) |
| Crimson-Police: open Dispatch | Opens the tablet on the Dispatch screen | none (`Config.Tablet.dispatchKey`) |
| Crimson-Police: ready for the unit's mission | Answers a unit ready check with Ready | none (`Config.Tablet.readyKey`) |
| Crimson-Police: contact action (plate, place in vehicle, hand over, escort) | The police action shown on screen during a mission | none (`Config.Tablet.contactKey`) |
| Crimson-Police: test controls and invitations | Test run controls for admins, or the test invitation for testers. Press again to free the mouse | **F7** |

- A default key you set in `config.lua` only reaches players who never had that key before. Players who already
  joined keep their own choice.
- Mission Builder keys, shown on screen while you use a builder tool: **E** (or the horn) place or set,
  **Backspace** undo, **Enter** done or finish, **P** pause or resume, **X** stop point, close or stop a test drive,
  **mouse wheel** radius or rotate, **Shift** fine steps.

### 8.3 Exports for other scripts

| Export | Side | What it does |
|---|---|---|
| `exports['Crimson-Police']:OpenTablet()` | client | Opens the tablet, with the same officer checks as `/CrimsonPolice` (on duty, department job, not suspended; the item when `requireItem = true`). It works even when `access.command = false` |
| `exports['Crimson-Police']:GetDepartment(src)` | server | The department key of the player's active job (`'sast'`, `'fib'` ...) or `nil` |
| `exports['Crimson-Police']:IsOnMission(src)` | server | `true` while the player is on a Crimson-Police mission |

The tablet item uses the client export `useTablet` (`export = 'Crimson-Police.useTablet'` in the item).

---

## 9. How it plays

### 9.1 The officer's tablet

The tablet uses the officer's department colours and logo. Eight screens on the left:

| Screen | What is on it |
|---|---|
| **Home** | The officer's card (picture, callsign, rank, level, streak, season points, cash this week), today's and this week's goals, Type of the Day, open mission calls, new commendations, and the Rewards locker when item rewards are on |
| **Mission Board** | One card per mission type with its pay and points, locks (cooldown, "Server busy", "On a call", daily limit), the Weekly Boss card from Friday to Sunday, and the Cross-Department card when one is running |
| **Dispatch** | Tablet mission calls to claim, the last 5 calls, and a read-only count of real sc-dispatch calls. Hidden when `Config.MissionCalls.enabled = false` |
| **Unit** | Invite officers (nearest first), accept or decline, leave; the leader can kick, make leader or disband. A ready check runs before every mission |
| **Active Mission** | The drawn mission, objectives, timer, partners, expected pay, the route to the start, and the Contact panel for police actions |
| **Leaderboard** | Weekly, Monthly, Season and All-time boards, ranked by points, missions, arrests, impounds, citations, rescues, mission calls or judgement |
| **Department Challenge** | Each department's score, weeks left, this week's bounty and the top 5 |
| **Profile & History** | Picture, bio, level, service record, badges, commendations, the last 20 runs, disputes, and the tablet's look |

Also: badges on the sidebar, a notification bell with the last 20 messages, the mission HUD on screen, and a
result card after each mission.

**How a mission goes.** The officer (or unit leader) picks a type. The server draws a random mission of that type
(no list, no reroll). Everyone gets a GPS route to the start and must follow it: 30 seconds off the route ends
their run as Abandoned. At the start the mission begins; they finish the objectives before the timer runs out.
Finished = Completed (points and cash). A downed officer, or a timer that runs out, = Failed. Leaving, going off
duty or not reaching the start in time = Abandoned. Going down, leaving, going off duty or not reaching the start
also puts a 5-minute cooldown on that whole mission type (`Config.Limits.abandonCooldown`). Ending for a real
call, or a supervisor's force recall, never does. An admin can clear an officer's cooldowns, allow a few more
missions today or give another Weekly Boss attempt ([9.15.3](#9153-live-runs-units-and-anti-farm)).

### 9.2 The supervisor's screens

Supervisors play missions like officers. The **Supervisor** button in the tablet opens their own screens:

| Screen | What it is for |
|---|---|
| **Mission List** | Every mission by name. Launch a Cross-Department Mission from here |
| **Cross-Department Mission** | The running operation: start now, relaunch after a fail, cancel, remove a joiner |
| **Live Missions** | Runs of their department: force recall. Its Mission calls panel withdraws, pages and creates calls. Admins have their own **Live** screen for every department, with more controls ([9.15.3](#9153-live-runs-units-and-anti-farm)) |
| **Review Queue** | Flagged runs and disputes of their department, and a **Profiles** tab for pictures, bios and reports |
| **Payouts** | Mission type payouts, within the allowed range |
| **Mission Builder** | Build, test and publish their own missions ([9.12](#912-mission-builder)) |
| **Department Report** | Activity per officer this week, and **Commend** |

Which of these they can use is set in `Config.Permissions.supervisor` ([4.4](#44-what-supervisors-may-do)).

### 9.3 The admin panel

`/CrimsonPoliceAdmin` opens a full-screen panel for every department:

| Screen | What it is for |
|---|---|
| **Payouts** | Every type and mission payout; set or clear them |
| **Payments** | Every payment Crimson-Police made or still owes, with totals and the payment tools ([9.15.4](#9154-payments-item-rewards-and-department-money)) |
| **Missions** | Built-in and custom missions: Builder, publish, archive, restore, roll back, break edit locks, reload files, Cross-Department Missions and mission calls |
| **Seasons & Challenge** | Start or end a season, override this week's bounty |
| **Leaderboards** | Every board, cash paid, payments stuck in "paying", void runs, award points, and the **Item rewards** tab |
| **Officers** | Search officers: history, suspend or unsuspend, disputes about failed runs, profile moderation, commendations, service record |
| **Departments** | Each department's jobs, colours, logo, desks, member count and (with society payouts) account balance |
| **Missions** (switches) | Turn any mission, or single locations of it, on or off ([5.8](#58-turn-missions-and-locations-on-or-off)) |
| **Permissions** | What supervisors may do (a switch for each), and **Config health**: the start-up check, with a **Check again** button |
| **Live** | Every live run and unit, with the controls to recall, end, add time or split a unit ([9.15.3](#9153-live-runs-units-and-anti-farm)) |
| **Settings** | Every setting of `config.lua` and `blocks.lua`, changed in game, with a change history ([5.7](#57-change-any-setting-in-game-the-settings-screen)) |
| **System** | Storage, backups, the webhook states, recent console problems, the other resources and the nightly clean-up ([9.15.5](#9155-system-departments-and-settings)) |
| **Audit Log** | Every supervisor and admin action, with filters and a CSV export |
| **Testing** | Optional: every mission and location with its test result, test runs, testers, and an area coverage table ([9.13](#913-testing-tools)) |

### 9.4 The missions

18 missions plus the Weekly Boss. "Officers" is the unit size the mission accepts.

| Type | Mission (id) | Officers |
|---|---|---|
| Patrol | Beat Patrol (`beat_patrol`) | 1 |
| Patrol | Business Check (`business_check`) | 1 |
| Patrol | Street Race Bust (`street_race_bust`) | 1–2 |
| Patrol | Illegal Parking Patrol (`parking_patrol`) | 1 |
| Patrol | Traffic Enforcement (`traffic_enforcement`) | 1–2 |
| Training | EVOC Course (`evoc_course`) | 1 |
| Training | Pursuit Sim (`pursuit_sim`) | 1 |
| Training | Stolen Vehicle Takedown (`stolen_vehicle_takedown`) | 1–2 |
| Investigation | Warrant Service (`warrant_service`) | 2–4 |
| Investigation | Manhunt (`manhunt`) | 1–4 |
| Investigation | Suspicious Activity (`suspicious_activity`) | 1–2 |
| Tactical | Gang Shootout (`gang_shootout`) | 1–4 |
| Tactical | Hostage Rescue (`hostage_rescue`) | 1–4 |
| Tactical | Bomb Disposal (`bomb_disposal`) | 1–4 |
| Tactical | Armored Truck Escort (`armored_truck_escort`) | 2–4 |
| Tactical | Prison Break (`prison_break`) | 1–4 |
| Tactical | Drug Lab Raid (`drug_lab_raid`) | 2–4 |
| Tactical | Gang Hideout Raid (`gang_hideout_raid`) | 2–4 |
| Tactical (Weekly Boss) | Weekly Boss: Kingpin (`weekly_boss_kingpin`) | 1–4, Friday to Sunday only |

- **Team size** sets the tier: Standard (1), Reinforced (2), Heavy (3–4), Major (5–6) and Critical (7–8). More
  officers = more NPCs, better armed, and more points and cash. Major and Critical only happen in Cross-Department
  Missions.
- **Cooldowns and limits**: each mission has a cooldown, officers finish at most 8 missions an hour, and at most 12
  missions run at once on the server (4 of them Tactical).
- **Real calls first**: responding to a real sc-dispatch call, or being assigned by a dispatcher, ends the mission
  at once with no penalty. sc-npcpolice calls never end a mission.
- **No alerts**: mission gunfire and downed officers make no sc-dispatch or sc-ambulance alerts.
- **NPC weapons and damage**: armed NPCs carry pistols and pump shotguns only (never SMGs or rifles), aim worse, fire
  single shots and do half damage; an officer on a run takes no extra headshot damage. All of it is
  `Config.NpcCombat` ([5.9](#59-how-hard-npcs-fight-back)).
- **Downed**: a downed officer has Failed. With no EMS on duty they are picked up after 15 seconds and taken to a
  drop-off point. With EMS on duty, an EMS request is sent for them.
- Custom missions from the Mission Builder join their type's pool when they are published.

### 9.5 Dispatch: mission calls

The tablet posts its own NPC calls every one to two and a half minutes (`Config.MissionCalls`). A call shows a code,
a radio-style title, the type, a priority (Tactical P1, Investigation P2, Patrol P3), an area and a countdown. It
never names the mission. The first unit leader (or solo officer) to claim it gets a random mission of that type in
that area. Nearby units get the first 15 seconds. Reaching the start fast earns +10% points (rapid response).
Mission calls never go to sc-dispatch. Supervisors and admins can withdraw a call, page a unit or create a call.
Staff-posted calls wait 2 minutes between them; an admin may **Post anyway** with a reason.

### 9.6 Police actions and custody

Some missions put officers in front of people and cars with a hidden story: a parked car, a driver at a traffic
stop, someone hanging around a shop. The server decides what is really going on (a warrant, drugs, a gun, a stolen
car, or nothing).

- Officers find out with police actions, through ox_target on the person or car: talk and check ID, frisk, run
  the plate, look inside, inspect, order out, search a person or vehicle (a search needs a lawful reason) and detain.
- Then they decide: release, verbal warning, citation, arrest, impound or no action. The server grades each
  decision (Best, Acceptable or wrong) against the truth. Releasing someone after finding their gun or warrant
  fails the case, and the tablet warns first. Nobody loses points for something no lawful action could have found.
- Arrested NPCs are handed over to an NPC **prisoner van**. Impounded cars leave on a Crimson-Police **tow truck**.
  "Process the scene" calls a **coroner van**.
- Actions with no ox_target spot (run a plate from your car, place in vehicle, hand over, escort) are on the
  contact key ([8.2](#82-keys)) and on the Contact panel.

### 9.7 Raids

**Drug Lab Raid** and **Gang Hideout Raid** are Tactical missions for 2–4 officers. Each run can roll different
behaviour and spawns, and the Active Mission screen shows an intel line so the unit knows what to expect. The crew
is already in place while you drive in and stack up: placed away from you (`Config.Spawning`), calm and unarmed until
the breach, when they all arm and fight. Shoot one, or walk up to one away from the doors (`stageWakeRange`), and they
wake early.

### 9.8 XP and levels

Every point an officer earns is also XP. XP gives a level from 1 to 50, then a prestige star for every 10,000 XP.
Level names (`Config.XPLevels`): Probationary, Patrol Officer, Senior Patrol, Veteran and Elite. Levels are for
show only: they never change the Qbox rank, pay or missions. They unlock looks (picture presets and accent colours),
and an optional level-up item if you set one in `Config.Rewards.levels`.

### 9.9 Leaderboards

Four boards: Weekly (resets every Monday), Monthly, Season and All-time (all-time XP). Filters by type, unit,
cross-department and department. "Rank by" points, missions, arrests, impounds, citations, rescues, mission calls
or judgement (the share of best decisions). Officers need 3 finished runs in the period to show. The top 25 show,
plus your own row. Cash is never shown. Officers can hide their name in their profile.

### 9.10 Department challenge and seasons

An admin starts a season (`/CrimsonPoliceAdmin season start Summer` or Admin UI → **Seasons & Challenge**) and ends
it when they like (8 weeks is suggested). During a season the departments compete: by default the score is the
average season points per active officer, so a small department can win. Every Monday a weekly bounty is picked at
random (for example "Most Tactical missions"), and the winning department gets +10% of its challenge points that
week. The winner gets a "Summer Champions" banner (named after the season), a trophy badge for its officers with 3
or more finished runs, and a Discord post (when `cp_webhook_board` is set).

### 9.11 Disputes, flags and suspensions

- **Flagged runs**: runs that look wrong (impossible speed, outside help, an officer who wasn't there) are flagged.
  Their points and cash are held until a supervisor or admin approves or voids them.
- **Disputes**: an officer can dispute a flagged, voided or failed run from **Profile & History** within 48 hours.
  Flagged or voided runs go to supervisors of the run's departments; failed runs (for example a bug) go to admins.
  If no supervisor can answer, admins get it. The answer is final.
- **Automatic suspension**: 3 voided runs in 30 days suspend the officer from Crimson-Police for 7 days
  (`Config.AntiCheat`).
- Admins suspend by hand in Admin UI → **Officers**, or with `/CrimsonPoliceAdmin suspend <citizenid> <days> [reason]`.

### 9.12 Mission Builder

Supervisors (Supervisor UI → **Mission Builder**) and admins (Admin UI → **Missions** → Builder) make new missions
in game, with no coding:

1. Pick up to 6 objective blocks (fight waves, pursuit, escort, search an area, rescue, skill check and more).
2. Fill in the details: name, type (it sets the points and pay), difficulty, officers, time limit, cooldown and
   which departments may get it. There is no payout field. Only admins can add mission items
   ([4.5](#45-mission-builder-permissions)).
3. Place spots in the world and record road routes by driving them.
4. Test it privately if you like. **Testing is optional**: a draft can be published without a test (the tablet asks
   "Publish without testing?" once). Only when `Config.Builder.requireTestToPublish = true` must a supervisor's draft
   pass a test first; an admin never needs one.
5. Publish. The mission joins its type's pool, and a Lua file is written to `Crimson-Police/missions/custom/<id>.lua`
   (with a `.bak` copy of each old version).

A developer can edit that file by hand, then run `/CrimsonPoliceAdmin reload` to load the change as a new version.
Mission files are **data files, not scripts**: the server reads them and never runs them. Keep to the layout the
Builder writes: one `RegisterMission({ ... })` holding plain values (text in quotes, numbers, `true`, `false`,
`nil`, `{ ... }` tables, and `vec3(x, y, z)` / `vec4(x, y, z, w)` with plain numbers), plus `--` comments. Sums
(`10 * 60`), joined text (`'a' .. 'b'`), variables, `local`, functions, loops and a key written twice are refused.
The console line and Admin UI → **Missions** → **Load result** name the file and the line of a refused file, for
example `missions/custom/night_beat.lua:12: a mission file holds only RegisterMission({ ... }) with plain values
(no code, variables or sums) near '*'`. A refused hand edit is not taken in: the mission (custom or an edited built-in) keeps
playing its last published version until the file is fixed.
Nothing can be placed in `Config.Builder.noBuildZones` (stations, hospitals, the prison, Crimson-Arena).

Admins can also open any **built-in** mission in the Builder and edit it; the edit replaces the built-in under the
same id and **Reset to original** brings the shipped file back ([9.15.2](#9152-missions-and-the-mission-builder)).
While `Config.Builder.enabled = false` the Builder is off for supervisors only; admins keep it.

### 9.13 Testing tools

Admins can play any mission on demand to check it works. **Nothing in a test run is saved or paid.** Testing is
optional: no mission, location or draft needs a test before it is used or published.

- Start one in Admin UI → **Testing**, or in game with `/CrimsonPoliceAdmin test <missionId> [tier] [location|random]`,
  for example `/CrimsonPoliceAdmin test gang_shootout heavy 2`.
- Pick the location and the tier yourself, whatever the number of testers. Invite up to 7 more players
  (`Config.Testing.maxTesters = 8`, you included); they accept with **F7**.
- Press **F7** during the test for the controls: skip or restart an objective, pause the timer, force complete or
  fail, debug overlay, teleport to the start or the objective, and end the test.
- After each test, mark it **Passed** or **Failed** with a note. The Testing screen shows every mission and
  location as Passed, Failed, Not tested or Changed since test. These are notes for you: an untested mission works
  like any other.
- **Mark checked (not played)** notes a location you looked at without playing, and **Results** removes a wrong
  result (or shows it again). Each mission row has its on/off switch.
- **Check spawn points** (`Config.Testing.spawnCheck`): Admin UI → **Testing** → **Check spawn points** (or the pin
  on a location row). Pick **All missions**, one mission or one location and press **Start the check**: your own
  game visits every point and tells you which ones are under the ground, floating, in water, in a wall or inside a
  building that never loads. You are frozen, unseen and unhurt while it runs, and back where you were when it ends;
  nothing is spawned and nobody else moves. **Stop** ends it after the point being checked. The results list each
  point to look at (mission, location, point such as `spawns[7]`, what is there, x y z, the ground and the height
  over it, notes such as "12.3 m from the start"); **Teleport here** takes you to one of them (`teleport = false`
  hides it) and **Copy report** copies every problem, one line each, to send to whoever fixes the files. You may
  close the tablet while it runs: the results wait in the dialog. Every bad point is also a console line (and a line
  in **System → Problems**), for example
  `spawn check: gang_shootout #4 spawns[7] (1153.75, -3169.50, 5.88) UNDERGROUND ground 6.40 (-0.52) [ped]`.
  Route points are skipped unless `routes = true` (that takes much longer).

### 9.14 Rules to tell your officers

- Real RP first. When a real call comes, take it: responding ends the mission with no penalty.
- Don't mark responding just to escape a bad mission: un-marking within 60 seconds counts as a normal abandon.
- Follow the GPS route to the start. Leaving it ends your run.
- Drive and act in character: normal pursuit and code 3 rules apply on missions too.
- No farming and no exploits. Report bugs to command.
- Only team up with officers who really play the mission with you. Joining only for the pay voids the run.
- Never use a real player as a mission target.
- Keep mission fights off the radio and off the panic button: missions never need real units.
- Don't go down on purpose: it fails your run and puts that mission type on cooldown.
- In a Cross-Department Mission, follow the lead of the supervisor who launched it.
- Never use sc-police's `/imp` or `/depot` on mission cars. Use the tablet's **Impound**.
- Disputes go through **Profile & History** within 48 hours.

A suggested discipline ladder: a verbal warning, then the run voided, then a 7-day Crimson-Police suspension, then
removal. Three voided runs in 30 days suspend an officer for 7 days by themselves.

### 9.15 Full admin control

Everything an admin may want to change is a button in `/CrimsonPoliceAdmin`: no file to edit, no console command and
no database tool. Who is an admin does not change (the `crimsonpolice.admin` ace from server.cfg, your Qbox admins
while `Config.QboxAdmins = true`, and the server console), and supervisors get nothing new. A few rules hold for
every admin tool:

- **A reason** is asked wherever a record changes, and it goes into the audit log with your name and your player
  licence, so every character of one player can be found.
- **A typed word** guards the dangerous ones: for example `VOID 12` before voiding 12 runs, the citizen ID before
  retiring an officer, or `ENABLE` before turning on a money tool.
- **A preview** shows exactly what a bulk change will do before it runs. If the data changes in the meantime, the
  change is refused and you look again.
- **Never your own records**: no admin can correct, pay or adjust any of their own characters, or a run one of them
  took part in. Another admin, or the server console, can.
- **One click, one action**: a double click or a slow connection never pays or changes anything twice.
- **Bulk changes** run one at a time in the background with a progress bar, and every one can be undone as a batch.
  A restart in the middle finishes the job (or stops it cleanly) at the next start.
- **Maintenance**: while a storage copy, a storage switch or a backup restore runs, a banner shows on every tablet
  and no new mission, call, test or payment starts. When it is done, the Admin UI (and one console line) say:
  "Restart Crimson-Police now from txAdmin or the server console". Crimson-Police never restarts itself.

#### 9.15.1 Officers, points and boards

**Officers** has four tabs: **Officers** (search and the officer's record), **Review** (every pending picture, bio
and profile report, and the banned-words list), **Disputes** (every open dispute) and **Corrections** (every bulk
void, retirement, record move and season reopen, each with **Undo**). Search finds officers by name, callsign or
citizen ID and can filter by department, online, suspended, retired, off the boards, needs review, open dispute and
flagged run. An online character who never finished a run is found by typing their citizen ID.

On an officer's record:

- **Points**: their week, month, season and all-time points and rank. **Adjust points** adds points or takes some
  away (−10,000 to +10,000, a reason each time). It is a new line in their history, never an edit of an old run; to
  undo it, void that line. A deduction can never take their season points or XP below 0, and from 500 points up you
  type their citizen ID to confirm (`AdminControl.adjustConfirmAbove`). `AdminControl.adjustDailyLimit` caps what one
  admin may adjust per day (all characters of one player together); `AdminControl.pointAdjust = false` turns deductions off.
- **XP**: **Check XP** compares their stored XP with what their runs give; **Fix** writes the runs' value.
- **Streak**: the live streak, its multiplier and grace day. **Recalculate** rebuilds it from their runs; **Forgive
  days** covers missed days (server downtime) once a day, up to `AdminControl.streakForgiveMax` days.
  **Make available again** gives back today's first-run bonus, once per officer per day.
- **Goals**: today's and this week's goal; **Mark complete** pays a goal a bug blocked (never twice in one period).
- **Look**: **Reset look** (appearance, accent and size back to the defaults) and **Let them edit now** (clears the
  profile change cooldown). Their "hide my name" and "mute calls" choices are shown, never changed.
- **Badges**: how each badge came (earned, granted or blocked). **Grant** keeps a badge whatever the runs say,
  **Revoke** takes one away for good, **Back to automatic** lets the runs decide again, **Re-check** recounts them.
- **Record**: **Refresh from Qbox** (callsign, rank and name come from Qbox and are never edited here), **Keep off
  the leaderboards** (a staff test character; their runs still count for their department), **Void runs…**,
  **Reset progression**, **Retire** / **Unretire** and **Move record…**.
- **Runs** tab: their whole history, the archive included, 25 per page with filters. Open a run to see its debrief,
  everyone on it, its dispute, the bank transaction ID of its payment and the goal rewards it completed, and to
  **Void** it (as a correction or as a strike, for everyone on it, with its goal rewards), **Restore** it, change the
  kind of a void, or **Flag for review**.
- **Suspend** now also takes an exact date and time, and the record shows the reason. An SC-Dispatch suspension is
  shown but is changed in SC-Dispatch only.

Voids and restores:

- **Void runs…** voids every run of an officer (or a department, a mission type, a mission or an operation) between
  two dates as **one batch**. The preview lists exactly what goes; type `VOID <number>` to start. Runs you or another
  of your characters took part in are always left out. A bulk void is a **correction** by default (no strike towards
  the automatic suspension); switch on **Counts as a strike** for cheating. **Corrections → Undo** puts the whole batch
  back, including cash that was only waiting because of it. At most `AdminControl.bulkMaxRows` rows per batch.
- **Reset progression** is the same for all of an officer's runs; **Undo** restores them.
- **Retire** (a deleted character, a banned player) voids all their runs as a correction, closes the tablet to them
  and hides their picture and bio from everyone else (nothing is deleted). It is refused while they are on a run.
  **Unretire** brings everything back.
- **Restore run** brings a voided run back at any time: its points, XP and held cash. Cash the server already forfeited
  stays forfeited.
- **Move record…** moves a re-created character's whole history (runs, badges, commendations, disputes, unpaid
  rewards) to the player's new citizen ID. Both characters must be offline, the new one must have no runs yet, and
  it must be the same player (the same license, or the player's license: and license2: as Qbox's `users` table keeps
  them: an old character made on QBCore and a new one made on Qbox). **Undo** moves it back.
  `AdminControl.recordMove = false` turns it off.

**Leaderboards** gains **Rank by** (any metric), **a past week or month** (up to 12 months back), **Void runs in this
window…** (the same batch tool, instead of a board wipe), **Open** on each run, and **Approve all rows of this run**
in the flagged panel. **Adjust points** works as on the officer's record. The **Recognition** tab shows exactly what
officers' Home shows, the last four closed weeks with their Officer of the Week (**Recount** after a void moves the
badge, **Post again** reposts the top 3 to Discord) and the **staff notices**: short plain-text notes on Home for
every department or a few, for up to 30 days. The weekly and monthly top 3 on Home are the Settings switches
`Leaderboard.announceWeekly` and `Leaderboard.announceMonthly`.

**Seasons** gains **Season tools**: **Rename**, **Plan the end** (the first daily reset on or after the date ends the
season and can start the next one by name; admins get a reminder a day and an hour before), **Reopen** the season
that just ended (within 24 hours; type its name) with **Undo reopen**, **Next week's bounty**, and each department's
contributors. Ending a season shows the champion, trophies and top 10 first and asks you to type the season's name.
Click a season to see its bounty weeks (**Recount** a closed week) and its champion (**Recount champion**, up to 14
days after the end). A season's start date and deleting a season stay out of the tablet.

Every change above is admin only (supervisors never get it, whatever `Config.Permissions` says), needs a reason and
is in the audit log.

#### 9.15.2 Missions and the Mission Builder

Everything below is in Admin UI → **Missions**. Supervisors keep the Builder as it was and get none of these tools.

**Edit any built-in mission.** Every built-in mission has **Edit in Builder**. It opens the mission in the Mission
Builder with everything in it: objectives, locations, spawns, routes, NPCs, cars, weapons, timings, bonuses and
text. When you publish, your edit replaces the built-in under the **same id**, so the boards, run history,
cooldowns, test results, mission calls and the on/off switches keep working. Nothing in `missions/builtin/` is ever
written: your edit is saved in `missions/custom/overrides/` (and in your database or `saves/`), so an update of
Crimson-Police never wipes it. The same rules as for a custom mission apply (allowed models, weapons and zones, the
hostile limits), except that anything the shipped file already uses may stay. There is still no payout field: the
type sets the pay. You can publish without testing (testing is optional for everyone).

- **Edited** and **Original changed** badges in the catalog. "Original changed" means an update of Crimson-Police
  changed the shipped file since you edited it. **Compare** shows what the update changed and how your edit differs;
  then choose **Keep mine** or **Take the new original**.
- **Reset to original** puts your edit away (it is moved to `missions/custom/overrides/archived/`, not erased) and
  the shipped mission plays again. You type the mission id to confirm.
- **Quick edit** (the sliders button) changes a built-in's cooldown, time limit, time to reach the start, and its
  NPC models, cars and weapons, without the Builder. The values apply on top of an edited version too; **Fold
  Quick edit values into the edit** makes them part of it.
- `Config.AdminControl.editBuiltins = false` (Settings) switches editing off: the edits are kept but not played, and
  the shipped missions play until you switch it back on.
- Runs that are already going keep the definition they started with.

**Custom missions.** **Versions** rolls a mission (or an edited built-in) back to any kept version, with a short list
of what changes, and **Load saved draft** brings back a draft that a hand edit of the file replaced. **Change owner**
hands a custom mission to another officer. **Delete permanently** (archived missions only; type the mission id)
moves its files to `missions/custom/deleted/`; the **Deleted** tab brings it back. **Copy as Lua** shows the
published file to paste on another server, and **Import** (top of the screen) checks a pasted file and makes a new
draft from it: payout fields are dropped, a used id gets a new one, and nothing is published until you publish it.
The pasted text is read as data and never run, the same way the server reads a mission file: anything that is not
`RegisterMission({ ... })` with plain values (a loop, a variable, a sum, a function call) is refused at once, and the
dialog shows the line and the text the loader stopped at. So a pasted file can't freeze the server.

**Switches.** Every mission and location, built-in, custom or edited, has its on/off switch (catalog, Testing,
Dispatch). Location switches are saved by the location's name: when an edit renames or removes a location, the
catalog shows "n location switches no longer match" with **Remap**.

**Load result.** A banner above the catalog says when a mission file (or an edited built-in) did not load at the last
start or reload, with the reason. The same appears as the `missions` line in Permissions → Config health.

**History and stats.** The **History** tab lists every Cross-Department Mission (who launched it, who took part, the
points; **Details** → **Void this operation's rows** opens the bulk void with that operation already chosen) and
every mission call (who posted it, who claimed it, how fast and how it ended). The **Stats** tab shows,
per mission and per type, the runs, completion, fail and abandon rates, the average time against the time limit,
the average points and cash, flags and voids.

**Testing and dispatch.** In **Testing**, **Mark checked (not played)** records that you looked at a location without
playing it (its own badge, never a passed test), and **Results** lets you remove a wrong result or show it again
(nothing is deleted). In **Dispatch**, an admin may **Post anyway** during the wait between staff-posted calls, and an
admin may launch a Cross-Department Mission during its cooldown with **Launch anyway**. Both need a reason and go to
the audit log.

#### 9.15.3 Live runs, units and anti-farm

**Live** (in the admin sidebar; the badge counts the runs going on now) shows every live run of every department,
test runs and Cross-Department Missions included, refreshed every 10 seconds. Click a participant's name to open
them in **Officers**. Each run card has:

- **Recall** a participant: they leave at once with no penalty and no cooldown, the others carry on.
- **+ minutes**: 1 to 10 minutes more on the mission timer, only while the timer runs. All additions to one run stay
  within `Config.AdminControl.runTimeAddMax` (600 seconds). The fast-finish bonus still uses the original time
  limit, so extra time never earns a bonus.
- **End run** (type `END`): everyone still on it leaves as Abandoned with no points, no pay, no penalty and no
  cooldown, and everything the run spawned is removed, exactly as at any other end. Anyone who is down is still
  picked up or gets EMS. A Cross-Department Mission ends as cancelled. **End test** does the same for another
  admin's test run.

The **Units** tab lists every unit with its members, its ready check and whether it is on a run. **Remove** takes one
member out and **Disband** splits the unit; both wait until the unit is no longer locked for a run, in a ready check
or on a run, and the members are told.

**Officers → an officer → Today & cooldowns** shows, counted from saved runs: their cooldowns, today's completed
missions against the daily, hourly and per-type limits, the cash paid today, their Weekly Boss attempt, their free
abandons (runs that ended for a real call) of the last 24 hours, and, while they are online, **Board as they see
it** (their type cards and why each is locked; never which mission they would get). The buttons:

- **Clear** one type's or one mission's cooldown, or **Clear every cooldown**: at most
  `Config.AdminControl.cooldownClearsPerDay` (3) per officer per day, and not while they are on a run. A restart
  keeps the clear.
- **Allow more today**: 1 to `extraRunsMax` (10) more completed missions than the daily limit, once per officer per
  day, until the daily reset. The hourly limit and each type's own limit stay.
- **Another boss attempt**: once per officer per week. Voiding a bugged boss run also gives its attempt back.
- **Treat as a normal abandon**: a free abandon becomes a normal one, so the type and mission cooldowns start now.

**Missions → Today** shows today's Type of the Day, whether the Weekly Boss is on today and which run modifiers are
switched on. **Change today's type** picks another type or none for today only; at the daily reset the normal roll
is back, and a restart keeps the choice. Single modifiers are switched on or off in **Settings → Events →
modifiers**.

Every one of these asks for a reason, goes into the audit log (cooldown, extra-run, boss and abandon changes post to
the flags webhook; run and unit changes to the operations webhook) and tells the officer when they are online. No
admin can use them on a run or unit they (or another of their characters) are part of, or on one of their own
characters. Setting a limit in `Config.AdminControl` to 0 switches that tool off.

#### 9.15.4 Payments, item rewards and department money

**Admin UI → Payments** lists every payment of every run: who, which mission, what the run earned, what was paid, and
why the rest was not (held, pending, capped, unfunded, forfeited, or stuck half way). Filter by status, department,
officer and dates; the tiles on top add it all up (per status and per department, how much the daily cap cut, how
many were capped today). **Export CSV** gives the same list for a spreadsheet (cells are made safe to open). The
sidebar shows how many payments are stuck, and the stuck-payments card on **Leaderboards** has **Open in Payments**
(the list filtered to "paying").

What you can do from a row (the buttons show only where they make sense):

- **Resolve** a payment stuck half way ("paying", after a crash or a Qbox error). It shows what Renewed-Banking
  recorded for that transaction id, and where the payment stopped (Crimson-Police now saves each step: claimed, the
  department paid, the officer got it). Then **Mark paid** (no money moves) or **Pay again** (see below). "Not found"
  in the bank history proves nothing, so look at the officer's balance too.
- **Pay now** for a pending payment of an officer who is online, and **Retry all pending** for everyone online. These
  use the normal pay flow, so nothing is ever paid twice.
- **Forfeit now** ends the dispute window of a voided run early; **Cancel payment** stops a held or pending payment
  while the run keeps its points. Both tell the officer.

**Money tools that ship switched off.** Each one is a switch in Admin UI → **Settings** (type `ENABLE` to turn it on;
it is logged and posted to the audit webhook). Test each one on a test server with Renewed-Banking before you use it.

| Switch (`Config.Cash`) | Button | What it does |
|---|---|---|
| `allowPayAgain` | Payments → Resolve → **Pay again** | Pays a stuck payment again with its own transaction id (`...-r2`). If the department already paid, it is not charged again. The officer must be online, and you tick "I checked: the money did not arrive" and type the amount. |
| `allowUnfundedRetry` | **Retry unfunded** (a row, or every unfunded row of a department) | After you put money in the department's account. The balance is checked first. Your own characters' rows are always left out. |
| `allowCapTopUp` | **Pay the rest** | Pays the part of a payment the daily cap cut, once (`...-r`). This goes over the officer's daily cap. |
| `restoreForfeited` | **Pay it after all** | For a run that was restored after its cash was forfeited: pays it now, and its item rewards come back too. |
| `allowClawback` | **Take back** | Takes cash back from an online officer's bank (never more than was paid, never below their balance). The department gets it back when it paid it. Each one has its own transaction id (`...-back1`, `...-back2`). |
| `allowManualCash` | **New payment** | Pays an officer by hand, for example to fix a wrong payout. Between $1 and `maxPayout`; at most `manualDailyLimit` per admin per day (all characters of one player together). It is not counted against the daily cap, and it waits until the officer logs in if they are offline. |
| `allowAddFunds` | Departments → **Funds** → **Add funds** | Puts new money in a department's Renewed-Banking account (at most `addFundsMax` at a time). Never a withdrawal. |

Every amount is worked out by the server, every one of these asks for a reason (and the dangerous ones for the
amount typed out), none of them works on one of your own characters, and a double click never pays twice.

**Departments → Funds** (on each department card) shows the account balance, what it paid today, this week and this
season, unfunded payments, and what admins added. `Config.Cash.lowBalanceWarn` (0 = off) warns in the Config health
list and once a day to that department's online supervisors when the balance is lower. A turned-off department's
unfinished pay still comes from its own account.

**Payouts** has two more buttons: **Unlock for supervisors** (keep the amount, and supervisors may move it again
within their range) and **Adjust all** (raise or lower every type payout and/or mission payout by a percentage or an
amount, with a preview of every old and new value; type `ADJUST`). A stored payout outside the current payout range
is marked.

**Leaderboards → Item rewards** gains filters (officer, status, source, dates) and buttons: **Resolve** a reward
stuck while being given (the officer must be online; if the item is in their inventory it was given; if not, it
counts as given unless you type `LOCKER` to put it back in the locker), **Deliver now**, **Cancel**, and **Take back**
(only with `Config.Rewards.allowTakeBack`, ships off: removes exactly that item from an online officer, also food
with a best-before time and bags, whose details ox_inventory fills in when it gives them). Settings →
Item rewards has a pool editor with an item picker (forbidden items left out) and the expected items and value per run
at each tier; every change is checked on the server, so the raw editor can't add a weapon either.

**System → Clean-up** shows the last nightly clean-up and **Run clean-up now** (admins, once per 10 minutes). The
clean-up never archives a run whose money or item rewards are not finished, and it waits while a bulk change runs.

#### 9.15.5 System, departments and settings

**System** (Admin UI → System) has six tabs:

- **Storage**: where Crimson-Police keeps its data (the database or the saves folder), the rows of every table, the
  version and which migrations ran. **Copy all data** copies every table from one storage to the other (a copy that
  would replace existing data needs the typed word `REPLACE`; a payment either side made stays paid, and a row is
  never paid twice or taken back twice because of the copy). **Switch
  storage** picks the storage for the next start: back up, copy, switch (typed word `SWITCH`), then restart
  Crimson-Police from txAdmin or the server console. A saves folder other than `saves` must be made by hand inside
  the Crimson-Police folder first (the server cannot create folders on Linux); the switch refuses a folder that is
  not there yet. The storage you leave is marked "left behind": if it is ever
  started again, nothing is paid or changed there, so nobody is paid twice. The choice is kept by the server, not in
  config.lua; `CrimsonPoliceAdmin storage mode reset` in the server console goes back to config.lua's
  `Config.Database`.
- **Backups**: **Back up now** saves every Crimson-Police table, your custom and edited missions, uploaded logos and
  the banned-words file in `saves/_backups/` (never sent to players). The last `Config.Backups.keep` (7) are kept;
  `Config.Backups.daily = true` makes one at every daily reset. **Restore** shows what it replaces first, makes an
  automatic backup, and needs the typed word `RESTORE`; then restart Crimson-Police. A restore never takes money back:
  a payment made after the backup stays paid, a given item reward stays given, pay still owed to an officer (waiting
  for them to log in, held or unfunded) is kept even when the backup is older than it, a void or Restore run made since
  stays as it is now, a record moved since stays with the new character, and the audit log, the settings history,
  department funding and the money switches are kept as they are now. The newest backup and the latest automatic one
  can't be deleted, and the backup you restore is never removed by keep N while it is put back (even the oldest of a
  full list). A damaged backup is refused before anything changes. If a restore stops part way, the money state is put
  back and payments, new runs and claims stay held, also after a restart, until a restore works: the banner names the
  automatic backup to restore (`Config.Backups.holdAfterFailedRestore = false` lets a restart end that lock instead).
- **Webhooks**: which Discord webhooks are on, and the exact server.cfg line to paste for each (with **Copy the
  line**). Webhook links are only ever set in server.cfg and are never shown in game.
- **Problems**: the last 200 warnings and errors since the start, by module. Webhook links, passwords and licences
  are cut out.
- **Integrations**: every resource Crimson-Police works with (running or not, its version), the checklist of
  [7](#7-settings-to-check-in-your-other-resources), and Crimson-Arena (running, players in the arena, its two
  no-build zones). Nothing here edits another resource.
- **Clean-up**: when the nightly clean-up runs (at the daily reset), how long runs stay in the live table and how long
  the audit log is kept, and what the last clean-up did. **Run clean-up now** (with a reason, at most once every 10
  minutes) does the same at once. Unfinished payments and item rewards always stay in the live table.

**Departments** (Admin UI → Departments):

- **Add department**: key (it can't change later), name, short tag, its Qbox jobs (a job belongs to one department
  only), supervisor grade, society account and colours copied from another department. A new department starts at 0
  this season. Also add its job to sc-dispatch `AllowedJobs` and sc-police `PoliceJobs`.
- **Edit**: name, tag, jobs, grade, account, colours, a logo link (https) or file (a link is used when both are set),
  and **Upload a logo** (PNG or WebP, at most 1 MB; it takes about 20 s: one 16 KB piece every
  `AdminControl.logoChunkGapMs` ms, so FXServer never drops you for sending too much). The upload replaces a logo link
  and shows after the next restart; until then the tablets keep the old logo. A job moves to another department only
  while no run is going.
- **Turn off** (typed short tag): nobody opens the tablet through it any more; its history, boards, disputes and
  unpaid pay stay, and its pay still comes from its account. Not while its officers are on a run, and one department
  always stays on. **Delete** is only for a department added in game that has no history.
- **Desks** tab: **Add a desk here** puts a mission desk where you stand, facing your way; edit, move, remove and
  teleport to desks. Changes show at once on every player's game.

**Settings** follow-ups:

- The lists of rows (no-build zones, drop-off points, mission call areas, Scaling, XP levels, avatar presets, the
  weekly bounty kinds) have row editors; every map position has **Use my position** and **Teleport to**.
- **Names**: rename offences, commendation kinds, badges and bonuses (English only). **Goals**: each daily and weekly
  goal with its own switch.
- Saving asks once more where a change has effects you can't see on the screen: a points value applies to runs that
  end after the change; a setting that reloads the missions first lists the missions it would break; switching
  `Cash.source` to the department accounts shows each account's balance and the pay it would then owe; and the
  weekly bounty kinds change the running season. **Badges** has **Re-check everyone's badges**. Next to the reset hour and the week start,
  the screen shows when the next daily and weekly reset happen.
- **History** keeps the full old and new value of every change; **Revert** puts the old value back (it asks again
  when the setting changed since). **Export / Import** moves your settings to another server: you see every change
  first, locked and unknown settings are skipped, and an import never turns a money tool on.
- Config health lines (Permissions and Settings) have **Open setting** or **Copy the line** where one fixes them. The
  retention can't go under 30 days for the audit log or 3 months for archived runs; `requireItem` needs a tablet
  item; the Admin UI text must stay readable on its background.

**Audit Log**: the action filter has a **Cash actions** choice (every money tool at once); filter also by target, role, reason text and one player (every character: click the people icon of a
row), click a target to see only it, **Export in parts** of 5000 rows, and **Save to server**
(`saves/exports/audit-<time>.csv`).

**Officers → Support** (an online officer): **Check access** says why the tablet won't open and how to fix it (the same
checks the tablet makes), **Give tablet item** (one, when they carry none), **Show state** and **Release screen**
(only Crimson-Police's own tablet, focus and fade).

**When the Admin UI can't open**, three server console controls bring it back, and nothing else needs the console:

- `CrimsonPoliceAdmin settings` lists the settings changed in game; `CrimsonPoliceAdmin settings reset <path>` and
  `CrimsonPoliceAdmin settings reset all` undo them.
- `CrimsonPoliceAdmin storage mode reset` (or `storagemode reset`) goes back to config.lua's storage at the next
  start.
- `set cp_settings_safe 1` in server.cfg starts Crimson-Police once without the settings changed in game (nothing is
  deleted; remove the line and restart to use them again).

---

## 10. Before go-live, updating and backups

### 10.1 Before go-live checklist

- ☐ The start-up check passes: type `CrimsonPoliceAdmin check` in the console ([3.4](#34-start-the-server-and-read-the-console)).
- ☐ Your department jobs exist and `supervisorGrade` is right ([3.3](#33-check-your-police-jobs), [4.3](#43-supervisors)).
- ☐ You and your staff can open `/CrimsonPoliceAdmin` ([4.2](#42-admins)).
- ☐ The payouts fit your economy ([5.3](#53-payouts)).
- ☐ Your logos are in `Crimson-Police/logos/` ([6.7](#67-department-logos)).
- ☐ The mission desks sit in the right place, or are off ([6.2](#62-mission-desks)).
- ☐ `Config.Debug = false` for a quiet console (it ships `true` for testing), and `Config.Database.enabled` is what
  you want: `false` (as shipped) saves to the `saves` folder, `true` uses your database
  ([5.5](#55-the-two-switches-at-the-top-debug-and-storage)).
- ☐ You read `config/banned_words.txt` and changed it for your community ([5.6](#56-other-settings-you-may-want-to-change)).
- ☐ Item rewards and picture links are what you want (both ship off: [6.3](#63-item-rewards), [6.4](#64-profile-pictures)).
- ☐ NPC difficulty fits your officers: `Config.NpcCombat` ships with no automatic weapons, accuracy at most 18 and
  half damage ([5.9](#59-how-hard-npcs-fight-back)). Lower = easier.
- ☐ Optional: try the missions you care about. The built-in locations were placed from map data and checked by
  tests, but not driven in game. Admin UI → **Testing** runs any mission at any location; a location that does not
  fit your map can simply be switched off ([5.8](#58-turn-missions-and-locations-on-or-off)). Nothing needs a test.
- ☐ Share the rules in [9.14](#914-rules-to-tell-your-officers) with your officers, and the Detach tip in
  [7](#7-settings-to-check-in-your-other-resources) with your dispatchers.
- ☐ Your anti-cheat allows Bomb Disposal's harmless explosion ([7](#7-settings-to-check-in-your-other-resources)).
- ☐ Make one backup and try one restore on a test server: Admin UI → **System** → **Backups**
  ([10.3](#103-backups)). A restore ends with "Restart Crimson-Police now"; do that from txAdmin.
- ☐ The money tools that ship off (`Config.Cash.allow*`, `Cash.restoreForfeited`, `Rewards.allowTakeBack`): leave
  them off, or try each one first on a test server with Renewed-Banking, ox_inventory and Qbox, as
  [9.15.4](#9154-payments-item-rewards-and-department-money) says.
- ☐ The admin limits fit your server: Admin UI → **Settings** → `AdminControl` (point adjustments, cooldown clears,
  extra runs, added run time). Setting a limit to 0 turns that tool off.

### 10.2 Updating

1. **Back up first** (see [10.3](#103-backups)).
2. Stop the server (or type `stop Crimson-Police` in the console).
3. Move your old `Crimson-Police` folder out of `resources` (keep it until the update works).
4. Put the new `Crimson-Police` folder in its place.
5. Copy these from your old copy into the new one, replacing the new ones:
   - `config/config.lua` and `config/banned_words.txt` (and `config/blocks.lua` only if you changed it)
   - `logos/`
   - `missions/custom/` (your Mission Builder missions, with `archived/`, `overrides/` (your edited built-in
     missions), `deleted/` and the `.bak` files)
   - `saves/` (your data, when the database is off)
6. Compare your `config.lua` with the one in the download, and copy any new blocks into yours. At start, the
   console names any section your `config.lua` is missing, in a line like
   `[crimson-police:config] Config.X is missing: ...`. The settings you changed in game (Admin UI → **Settings**)
   are kept by themselves: they live in your database or `saves/`, not in `config.lua`.
7. Start the server (or, if you only stopped Crimson-Police, type `refresh` and then `ensure Crimson-Police` in the
   console). New tables are made by themselves (`applied migration ...` lines). There is never SQL to import.

The tablet's screens come ready-built. You never need to build anything (no npm).

### 10.3 Backups

- **In game**: Admin UI → **System** → **Backups** → **Back up now** saves every Crimson-Police table, your custom and
  edited missions, uploaded logos and the banned-words file in `Crimson-Police/saves/_backups/`. It works with the
  database on and off. `Config.Backups.daily = true` makes one at every daily reset, and the last
  `Config.Backups.keep` (7) are kept. **Restore** shows what it will replace, makes an automatic backup first and
  needs the typed word `RESTORE`; then restart Crimson-Police from txAdmin or the server console. A restore never
  takes money back: a payment made after the backup stays paid, and the audit log is kept as it is
  ([9.15.5](#9155-system-departments-and-settings)). If a restore stops part way, payments stay held (also after a
  restart) until you restore the automatic backup the banner names, then restart.
- **Outside the game**, before every update:
  - **Database on**: back up your database (all the `cp_` tables), like you do for Qbox.
  - **Database off**: copy the whole `Crimson-Police/saves/` folder (it holds `_backups/` too) while the server is
    stopped.
  - Either way, also keep a copy of `config/`, `logos/` and `missions/custom/`.

---

## 11. Troubleshooting

Crimson-Police lines in the console start with `[crimson-police]`. Yellow `[crimson-police:<part>]` lines are
warnings and red ones are errors. Most start-up lines already say what to do.

### 11.1 The tablet does not open

What the player sees, and what to do:

| Message | Why | Fix |
|---|---|---|
| "Crimson-Police is only for officers whose active job belongs to a department." | Their active job is not in any department's `jobs`, or the job doesn't exist in Qbox | Check [3.3](#33-check-your-police-jobs) and the start-up check's `departments` lines. With sc-multijob, the police job must be the **active** one |
| "You need to be on duty to use Crimson-Police." | Off duty | Go on duty |
| "You are suspended from Crimson-Police." | Suspended by an admin or by 3 voided runs | Admin UI → **Officers**, or `/CrimsonPoliceAdmin suspend <citizenid> 0` lifts it |
| "You are suspended in SC-Dispatch and cannot use Crimson-Police." | Suspended in sc-dispatch | Lift it in sc-dispatch |
| "You need the police tablet in your inventory." | `requireItem = true` and no item | Give them the item, or set `requireItem = false` ([6.1](#61-the-tablet-item)) |
| "That way of opening the tablet is switched off on this server." | That way is `false` in `Config.Tablet.access`, or they used the item while `Config.Tablet.item` is not set | Switch it on, or use another way |
| "This mission desk is not for your department." | The desk's `departments` doesn't list theirs | Change the desk's `departments` ([6.2](#62-mission-desks)) |
| "Stand at the mission desk to open the tablet there." | Too far from the desk | Stand at the desk |
| "You can't take a mission while you are in the arena." | They are in Crimson-Arena | Leave the arena |
| "Only supervisors can open the Supervisor UI." | Grade below `supervisorGrade` | [4.3](#43-supervisors) |
| The item does nothing | The item name or `export` line is wrong, or `Config.Tablet.item` is not set | Read the start-up check's `items` lines ([6.1](#61-the-tablet-item)) |

**Quickest check:** Admin UI → **Officers** → the officer → **Support** → **Check access** runs the same checks
the tablet makes and says which one fails and how to fix it. **Give tablet item** hands them one tablet when they
carry none, and **Release screen** frees a stuck tablet screen.

On the Mission Board, "Server busy: too many missions are running. Try again shortly." means 12 missions (or 4
Tactical) are running server-wide (`Config.Limits`). "You are responding to a real call." means they are on a real
sc-dispatch call. "Mission calls are turned off on this server." means `Config.MissionCalls.enabled = false`.

### 11.2 Admin UI

| What you see | Fix |
|---|---|
| "Only admins can open the Admin UI." | The player is not an admin. The server console prints one line with their name and the exact `add_ace identifier.… crimsonpolice.admin allow` line to paste ([4.2](#42-admins)) |
| Start-up check: `admins: No admin group can open the Admin UI yet. Add this line to server.cfg and restart: add_ace group.admin crimsonpolice.admin allow ...` | Add the line from [3.2](#32-paste-this-into-servercfg). Ignore it if you give the ace to each admin yourself |
| "Load a character before using the Mission Builder." / "Load a character first." | The Builder and test runs need a loaded character |
| "Test mode is turned off in Config.Testing." | Set `Config.Testing.enabled = true` |
| "The Mission Builder is turned off." | Set `Config.Builder.enabled = true` |
| "You took part in this run, so you can't review it." | By design: another supervisor or admin must review it |
| "That feature is not available on this server right now." | A part of Crimson-Police failed to start. Read the red lines in the console from the last start |

### 11.3 Start-up check lines

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
| `items: <item> is not an ox_inventory item` | The item was not pasted into ox_inventory | [6.1](#61-the-tablet-item) step 1, then restart ox_inventory |
| `items: ox_inventory/web/images has no <item>.png` | The picture was not copied | [6.1](#61-the-tablet-item) step 2 |
| `items: ox_inventory is not running` | ox_inventory is stopped | Start ox_inventory |
| `items: requireItem is on but Config.Tablet.item is not set` | Only desks can open the tablet | Set `Config.Tablet.item`, or `requireItem = false` |
| `items: <item> is set but Config.Tablet.access.item is false` | Using the item does nothing | Set `item = true` in `Config.Tablet.access` |
| `desks: Desk <n> (<label>): coords is not a vec3` | A desk has bad coordinates | Write it as `vec3(x, y, z)` |
| `desks: Desk <n> (<label>): size is not a vec3` | A desk's size is written wrong | Write it as `vec3(1.2, 0.8, 1.0)` |
| `desks: Desk <n> (<label>): unknown department <x>` | A desk names a department that doesn't exist | Fix `departments` of that desk |
| `desks: ox_target is not running` | No desk can work | Start ox_target |
| `colours: <DEPT>: theme.<key> is not a 6-digit hex colour` | A colour is written wrong | Write it like `'#1f4e8c'` |
| `colours: <DEPT>: personal accent <n> ...` | An entry of `personalAccents` is wrong or listed twice | Write it like `'#4cc9f0'` or `{ colour = '#80ed99', level = 10 }` |
| `tweaks: Config.MissionTweaks.<id>: there is no mission with that id` | A tweak names an unknown mission | Fix the id ([9.4](#94-the-missions)) |
| `tweaks: Config.MissionTweaks.<id> was ignored` | The tweak breaks a mission rule | The console line from the start says why |
| `locale: locales/en.json is missing` / `is not valid JSON` | The text file is broken | Copy `locales/en.json` again from the download |
| `avatars: ...` | A picture host is wrong or expires | [6.4](#64-profile-pictures) |
| `webhooks: cp_webhook_<name> in server.cfg is not an https:// link` | A webhook link is wrong | `set cp_webhook_<name> "https://discord.com/api/webhooks/..."` |
| `rewards: Item rewards: "<item>" (<pool>) does not exist in ox_inventory` | A reward item is unknown; it is turned off | Use an item that exists ([6.3](#63-item-rewards)) |
| `rewards: Item rewards: "<item>" (<pool>) can never be an item reward` | A forbidden item (weapon, ammo, money ...) | Pick another item |
| `rewards: Item rewards: example item "<item>" (<pool>) does not exist in ox_inventory` | Your ox_inventory has no `water`, `burger` or `sprunk` (the example items). This shows even while item rewards are off | Harmless while `useExamplePools = false`. To use item rewards, fill `byType` with your own items ([6.3](#63-item-rewards)) |
| `rewards: Item rewards: ox_inventory is not started` | Item rewards are on but ox_inventory is stopped | Start ox_inventory |
| `This check could not run: the server console has the error` | A check crashed | Read the red line in the console |

The last line of the start-up check is `Start-up check: all ... checks passed` or
`Start-up check: <n> warnings and <n> errors (each on its own line above, with the fix) ...`.

### 11.4 Database and saves folder

| Console line | What to do |
|---|---|
| `Migration <file> failed. Crimson-Police did not start.` followed by `Statement: ...`, `Error: ...`, for the usual errors `How to fix it: ...`, and `Crimson-Police stays started but refuses every request until it starts ...` | Crimson-Police could not make its tables (or read its saves folder). Do what the "How to fix it" line says, then type `ensure Crimson-Police` in the server console (or restart it in txAdmin). Usual causes: the database user may not create or change tables, a wrong password, or the database can't be reached. Or set `Config.Database.enabled = false` to save to files. FXServer never lets a resource stop itself, so Crimson-Police shows as started in txAdmin meanwhile: the tablet answers "Crimson-Police did not start" at once, every request is refused, and nothing is read or written. In the server console only `CrimsonPoliceAdmin check` and `CrimsonPoliceAdmin storagemode reset` (also `storage mode reset`) still work |
| `This is the storage switched to in Admin UI → System. To go back to config.lua's Config.Database, type "CrimsonPoliceAdmin storagemode reset" ...` | The storage switched to in game cannot start (for example a saves folder with a damaged file, or a database user without rights). Type `CrimsonPoliceAdmin storagemode reset` in the server console (it answers `The storage chosen in game is cleared ...`), then `ensure Crimson-Police`: it starts on config.lua's `Config.Database` |
| `Crimson-Police did not start (the console lines above say why). Only "... check" and "... storagemode reset" work ...` | You typed another `CrimsonPoliceAdmin` command (or opened the Admin UI in game) after a failed start. Fix what the start-up lines say, then `ensure Crimson-Police` |
| `The database server is <version>. Crimson-Police needs MariaDB 10.3 or newer ...` followed by `How to fix it: update the database server to MariaDB 10.9 or newer ...` | The database server is too old: it has no JSON_VALUE, or reads it differently, and every payment uses it. Nothing was touched. Update to MariaDB 10.9 or newer (Qbox's minimum; your host may offer it), or set `Config.Database.enabled = false` to save to files. Then `ensure Crimson-Police` |
| `the database server is MySQL <version>. Qbox does not support MySQL ...` | A warning: Crimson-Police starts, but Qbox is made for MariaDB, and on MySQL, once an officer has a cooldown clear, cap raise or extra boss attempt, the next one is refused, and a storage copy to the saves folder can reuse a deleted run's id. Move to MariaDB when you can |
| `cp_<table> is utf8mb3_general_ci: switching it to utf8mb4 (once), so names and reasons with emoji are kept` | Normal, once per table, on a database made by txAdmin's recipe (its `utf8` character set can't hold emoji): on the first start with the database on, or in a `storage copy files-to-database`. A big `cp_mission_runs` can take a while; let it finish |
| `cp_<table> could not be switched to utf8mb4, so names and reasons with emoji cannot be saved in it: ...` | Give the database user the ALTER right (the line's "How to fix it" says which), then restart. Until then a name or reason with an emoji in that table is not saved |
| `still waiting for the database after 30 seconds: oxmysql has not connected` | Check the oxmysql lines above it and `set mysql_connection_string` in server.cfg (user name, password, host, database name). Or set `Config.Database.enabled = false` |
| `first start with the database off: the saves folder ... is empty` | Normal on a new install |
| `the saves folder ... is new, so Crimson-Police starts with no data` | You switched the database off on a server that has data in the database. Run `CrimsonPoliceAdmin storage copy database-to-files`, then restart ([6.5](#65-database-off-the-saves-folder)) |
| `the database is new, but the saves folder holds data from running with the database off` | Run `CrimsonPoliceAdmin storage copy files-to-database`, then restart |
| `the saves folder ... cannot be written` | Keep `folder = 'saves'` (inside the Crimson-Police folder) and make sure the server may write there |
| `the saves folder ... is missing: create it by hand` | Make that folder by hand inside the Crimson-Police folder, then restart. The server cannot create folders on Linux (FXServer crashes when it tries), so Crimson-Police never does |
| `the saves folder ... could not be read: ...` | A file in the saves folder is broken. The line names it (with the folder in use, for example `saves/second/_tables.json`). Put it back from a backup with the server stopped, then start it again. Until then Crimson-Police refuses every request, as after a failed migration |
| `saves/<file> is missing: ...` | A saves file was deleted (the line names the folder in use). Put it back from a backup with the server stopped |
| "Active mission runs: 2. Copy when every run has ended." | Wait until no mission runs, then copy again |
| "The saves folder already has ... rows ..." (or "The database already has ...") | The target has data. Add `force` to replace it |
| "That data was made by a newer Crimson-Police ..." | Update Crimson-Police first |
| `Restoring <backup> stopped part way: ...` or `A backup restore did not finish ...` | A restore could not put every table back (or the server stopped during it). Nobody is paid twice: payments, new runs and claims wait. In Admin UI → **System** → **Backups**, restore the automatic backup the line names, then restart Crimson-Police |
| `backup <name> cannot be put back: <table> is missing or damaged` | That backup is broken or incomplete and nothing was changed. Restore another backup |
| `The automatic backup <name> of the restore that did not finish is missing or damaged` | No restore can run. To go on with the data as it is, set `Config.Backups.holdAfterFailedRestore = false` in config.lua and restart Crimson-Police |

### 11.5 Config and departments

| Console line | What to do |
|---|---|
| `config/config.lua did not load, so Crimson-Police cannot work.` | A typing mistake in `config.lua`. The first red error above it names the line (usually a missing comma, quote or bracket). Fix it and restart |
| `Config.X is missing: config/config.lua (or config/blocks.lua) stopped at an error, or it is from an older version.` | Fix the line a red error names, or copy the missing blocks from the new `config.lua` |
| `Department <key> lists no Qbox job names in jobs: nobody can use it.` | Put your job name in `jobs = { }` |
| `Department <key>: supervisorGrade must be a Qbox grade level` | Write a number, like `supervisorGrade = 3` |
| `Qbox job <job> is listed in departments <a> and <b>; <a> is used` | A job may only be in one department |
| `Department <key>: logos/<file> is missing` | Put the logo file in `logos/` and restart ([6.7](#67-department-logos)) |
| `Department <key>: logo.file ... must be a PNG, WebP or SVG file name in logos/` | Use a plain file name like `'sast.png'` |
| `Department <key>: theme.<key> is ..., not a 6-digit hex colour` | Write the colour like `'#1f4e8c'` |
| `Config.Departments key <key> must be letters, digits or _` | Rename the department key |
| `Config.Profile.bannedWordsFile ... was not found` | Put `config/banned_words.txt` back, or set `bannedWordsFile = false` |
| `Config.Downed.dropOffs has no valid point` | Write drop-offs as `vec3(x, y, z)` |
| `Department <key>: the tablet could not load its logo ... (reported by player <n>)` | The logo file or link is broken. Check the file in `logos/`, or the `logo.url` link |
| `Config.AdminTheme.<key> is not a 6-digit hex colour` | Write the colour like `'#a4161a'` |
| `Config.Challenge.scoring <x> is not average, total or top10; using average` | Use `'average'`, `'total'` or `'top10'` |
| `Config.Challenge.bounties is empty: no weekly bounty` | Put the bounties back, or set `weeklyBounty = false` |
| `Config.Rewards <pool>: "<item>" does not exist in ox_inventory; it is turned off` | Use an item that exists ([6.3](#63-item-rewards)) |
| `[crimson-police] <n> setting(s) changed in game are in use (Admin UI → Settings)` | Normal: the settings an admin changed in game are used ([5.7](#57-change-any-setting-in-game-the-settings-screen)) |
| `the saved setting <path> was ignored (<why>): config.lua's value is used.` | A setting saved in game is no longer allowed (often after an update). Open Admin UI → **Settings**, filter **Changed**, and change or reset it |
| `the settings changed in game could not be read: ...` | The database or saves folder could not be read: see [11.4](#114-database-and-saves-folder). Until it works, `config.lua`'s values are used |

### 11.6 Missions and the Mission Builder

| Console line | What to do |
|---|---|
| `missions loaded: 19 built-in (N edited), N custom, N rejected` | Normal. "rejected" above 0 means a line above says which file and why; Admin UI → **Missions** shows the same as the load result |
| `the edited version of <id> (<file>) was not loaded, the shipped mission plays: <reason>` | An edited built-in mission broke (often a hand edit of its file). Open it in Admin UI → **Missions** → **Edit in Builder** and publish again, or **Reset to original** |
| `custom mission <id>: edited in code, saved as version <n>` | Normal: someone edited that mission's Lua file, and the edit is now live |
| `mission <id> (<file>) was not loaded: <reason>` | For a custom mission, fix it in the Builder or the file. For a built-in one, copy the file again from the download |
| `... was not loaded: syntax error: <file>:<line>: ... near '<text>'` | That line of the mission file is not plain data (often a hand edit: a sum like `10 * 60`, a variable, joined text, or a key written twice). Write the plain value, like `600`, and run `/CrimsonPoliceAdmin reload` |
| `custom mission <id>: the edited file ... was not accepted` | A hand edit broke the mission. The old version stays live. Fix the file and run `/CrimsonPoliceAdmin reload` |
| `custom mission <id>: field "<name>" in its Lua file is ignored` | Payouts can't be set in mission files. Use the Payouts screens |
| `custom mission <id> (version <n>): items skipped: saved by a supervisor ...` | That version was published by a supervisor (or before Crimson-Police recorded who published it), so its runs hand out no items ([4.5](#45-mission-builder-permissions)). An admin opens it in the Mission Builder and publishes it again to give the items back, or removes them |
| `mission <id>: objective <n> names WEAPON_SMG, an automatic weapon: its NPCs carry WEAPON_COMBATPISTOL instead (Config.NpcCombat)` | Harmless: an older custom mission (or a `Config.MissionTweaks` entry) still names an automatic weapon, and its NPCs get the weapon named after "carry". To make the line go away, pick a pistol or a shotgun for it in the Mission Builder ([5.9](#59-how-hard-npcs-fight-back)) |
| `the folder Crimson-Police/<folder> is missing: create it by hand` | Make that folder by hand. Crimson-Police ships every folder it writes (`missions/custom/` with `archived/`, `overrides/`, `overrides/archived/` and `deleted/` inside it, `saves/_backups/`, `saves/exports/`), each with an empty `.gitkeep` file, so a missing one usually means the copy left empty folders out: copy the whole Crimson-Police folder again. The server cannot create folders on Linux (FXServer crashes when it tries), so Crimson-Police never does |
| `the folder Crimson-Police/<folder> is there but the server cannot write to it` | Give the user the server runs as write access to that folder |
| `built-in mission <id> cannot be unregistered; turn it off in Config.DisabledMissions` | Use `Config.DisabledMissions` |
| `cp_type_payouts has a payout for unknown mission type <type>; it is ignored` | Harmless. A type was removed from `Config.MissionTypes` |

### 11.7 Payments, webhooks and other lines

| Console line | What to do |
|---|---|
| `row <n> unfunded: society account <name> could not cover <amount>` | Put money in that Renewed-Banking account ([6.8](#68-paying-from-the-departments-bank-account)) |
| `... stays paying for a manual check (transaction CP-...)` | A payment may have half-happened. Open Admin UI → **Payments**, filter "Stuck (paying)" and press **Resolve**: it shows the Renewed-Banking history for that transaction id and where the payment stopped. Then **Mark paid**, or **Pay again** (a switch that ships off) |
| `convar cp_webhook_<name> must be an https:// webhook url; that webhook is off` | Fix that `set` line in server.cfg |
| `webhook <name> answered <code>: check its convar` | Discord refused the post. Check the link |
| `webhook <name> dropped after <n> tries ...` | Discord kept refusing that post. Check the link |
| `the webhook queue is full; the oldest posts are dropped` | Discord is slow or refusing posts. Check the links |
| `retention: <n> run rows archived, <n> audit rows deleted` | Normal: the daily clean-up of old data (`Config.Retention`) |
| `sc-ambulance is not started: ...` | Start sc-ambulance |
| `ox_inventory is not started: mission items are not given` | Start ox_inventory |
| `removed <n> crimsonArena flag(s) left over from a previous start` | Harmless after a crash or restart |
| `server clock moved back from ... to ...; no reset fired` | The server's clock changed. Nothing to do |
| `<n> seasons are marked active in cp_seasons; season <n> is used` | End the extra season in Admin UI → **Seasons & Challenge** |

If you can't find a line here, set `Config.Debug = true`, restart Crimson-Police, and keep the console output: the
extra lines help whoever looks at it.

### 11.8 The screen froze or the controls stopped

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

---

## 12. For developers

**Server owners don't need anything in this section.** The resource ships ready to run.

- **The web UI** lives in `Crimson-Police/web/` (React 18, TypeScript and Vite). The built files in `web/dist/` are
  committed, and FiveM loads only those. After a change to `web/src/` or `locales/parts/`, rebuild and commit
  `web/dist/`:
  ```
  cd Crimson-Police/web
  npm install
  npm run build     # type check, build and build stamp: writes web/dist
  npm run dev       # the UI in a browser at http://localhost:5173, with sample data
  ```
  The full UI developer guide (source layout, adding a screen, the NUI bridge, hooks, theme variables and
  components) is `docs/WEB_UI.md`.
- **Every check in one command**: `bash tools/check_all.sh` (syntax, contracts, lint, style, the test suites in all
  three storage modes, tsc and the web build). `tools/setup_test_env.sh` checks and installs what it needs.
  `.github/workflows/ci.yml` runs the same on GitHub.
- **Text** lives in `Crimson-Police/locales/parts/<part>.json`. `python3 tools/check_contracts.py --merge` builds
  `locales/en.json` from them.
- **Custom missions** published from the Mission Builder are `Crimson-Police/missions/custom/<id>.lua`. Edit one and
  run `/CrimsonPoliceAdmin reload` to load the change as a new version. Every mission file is read as data
  (`CP.U.parseMissionFile` in `shared/utils.lua`) and never run, so it keeps to the Builder's layout: one
  `RegisterMission({ ... })` of plain values and `vec3`/`vec4` of numbers.

**Files in this repository:**

| Path | What it is |
|---|---|
| `README.md` | This document |
| `Crimson-Police/` | The FiveM resource. Its `README.md` is a short install note |
| `Crimson-Police/items/README.md`, `logos/README.md`, `saves/README.md`, `web/README.md` | Short notes for each folder, pointing here |
| `docs/SPEC.md` | The product spec: every rule and feature (its Hard rules win over everything) |
| `docs/ARCHITECTURE.md` | Module APIs, the run model, the block interface, events and the NUI protocol |
| `docs/INTEGRATIONS.md` | Checked facts about the other resources (qbx_core, sc-*, Renewed-Banking ...) |
| `docs/CRIMSON_ARENA.md` | Rules for running alongside Crimson-Arena |
| `docs/WEB_UI.md` | The web UI developer guide |
| `docs/STYLE.md` | The code style. `python3 tools/restyle.py` formats the tree, `--check` lists what isn't |
| `docs/TESTING.md` | How to set up a machine, run the checks and read a failure |
| `docs/PROCESS.md` | How work gets done (branches, the gate, reviews) |
| `docs/FILE_NOTES.md` | The long file headers |
| `docs/notes/` | What each part of the build added (history) |
| `tests/` | Lua unit, SQL and end-to-end tests (`lua5.4 tests/run.lua`; needs a local MariaDB) |
| `tools/check_contracts.py` | Cross-checks of module calls, events, NUI names and locale keys |
| `tools/lint_fivem.py` | FiveM pitfall rules; known hits in `tools/lint_baseline.txt` |
| `tools/lua_flow.py` | The Lua parser and loop flow behind rule FX10 (`python3 tools/lua_flow.py --all <files>`) |

### Spec revisions

`docs/SPEC.md` was revised to match these owner-approved changes:

- Driving a vehicle instead of a police vehicle: Beat Patrol, EVOC Course and checkpoint routes with **Vehicle
  required** on count a checkpoint while the officer drives any vehicle (checked on the server).
- Extra builder peds: `Config.Builder.allowed.peds` includes the inmate, Kingpin and escort-driver models.
- Search-mission start radius: with a search area objective, every start radius equals its search circle (200–1000 m).
- Crimson-Arena no-build zones: the Trailer Park and the lobby are in `Config.Builder.noBuildZones`.
- Parity-plus: mission calls may be claimed on the Dispatch screen (the mission is still drawn at random after the
  claim); Traffic Enforcement, Illegal Parking Patrol and Suspicious Activity are allowed; the Officer UI has eight
  screens; bodies may be kept for a Process the scene objective. English only; item rewards ship off.
- Config defaults, at the owner's request: `Config.Debug = true` and `Config.Database.enabled = false`.
- Settings in game, at the owner's request ("admins get full control over everything in the admin tablet"): an admin
  can change every setting of `config.lua` and `blocks.lua` in Admin UI → **Settings**, and switch missions and
  locations on or off. This includes point settings, so the Points Hard rule now reads: officers and supervisors
  can never change points in game; an admin can, through the Settings screen (audited) or a manual award.
- Testing is optional, at the owner's request: publishing a Mission Builder draft needs no test
  (`Config.Builder.requireTestToPublish = false`); with it on, supervisors need a passed test and admins never do.
- Full admin control, at the owner's request ("admins get full control over everything in the admin tablet"):
  `docs/SPEC.md` has a **Full admin control** section. Admins may change point values (logged, resettable) and make
  a logged manual award **or deduction** (the Points Hard rule says so); admins may edit any built-in mission in the
  Mission Builder, saved as an override under the same mission id with **Reset to original** (the Mission Builder
  Hard rule says so); the money tools outside the normal pay flow are built and **ship off**, each turned on in
  Settings with the typed word `ENABLE`. Who is an admin, restarts and Discord webhook links stay out of the tablet.
- Stuck payments, at the owner's request (full admin control): the Cash payouts rule now says a payment left in
  "paying" is resolved in Admin UI → **Payments**: **Mark paid** (no money moves), or **Pay again** with its own
  `-r2` transaction id, behind `Config.Cash.allowPayAgain`, a switch that ships off.

- NPC combat, at the owner's request of 2026-10-19 ("make them also not do head shots at all also reduce the damage
  they shoot as they kill really quickly", no automatic weapons, lower accuracy): `Config.NpcCombat` ([5.9](#59-how-hard-npcs-fight-back)). Mission NPCs never carry an
  automatic weapon (the built-in missions, the Builder's allowed list and the block defaults name pistols and pump
  shotguns); NPC accuracy is at most 18, single shots, average skill, no charging, bursts from cars; NPC hits do half
  damage and officers on a run take no headshot multiplier; the server drops a one-shot kill by a mission NPC on a
  healthy officer of its run (at least `lethalCancelAbove`, three quarters, of his health) (the one `CancelEvent` Crimson-Police makes, `docs/CRIMSON_ARENA.md` rule 11). `MissionTweaks`
  `weapons` now also replaces the ambush, associate and boss weapons.
- Flee stamina, at the owner's request of 2026-10-19 ("I want the peds to run out of stamina when they run away"):
  `Config.Flee`. The server times every mission NPC that runs on foot (sprint 10 s, jog 12 s, walk 8 s, then worn
  out, each suspect up to 25 % longer or shorter, `fleeMult` of `Config.NpcDifficulty` now used; time in a car does
  not count), keeps the time across a fight or a surrender, and gives a runner his breath back after 20 s with no
  officer within 60 m. The game that owns a runner (any officer's, not only the host's) slows him down to match: a
  jog after 10 s, a walk after 22 s, held every frame, at `jogRate` / `walkRate` of the normal speed, with a jog and
  then a winded walk (`windedClipset`); a tired runner with no route left walks or jogs straight away from the
  nearest officer on the navmesh instead of GTA's flee task, which cannot be slowed. He sprints again when he gets
  his breath back, and is let go at once when he surrenders, fights or gets into a car. A worn-out runner gives up
  as soon as an officer is within `giveUpRange` (30 m), with no wait: he kneels (`exhausted = 'surrender'`), or stands
  with his hands up (`'handsUp'`), and can be cuffed; `'walk'` keeps the old rules only. This covers Warrant Service,
  Prison Break and the raids' runners, pursuit suspects who run from a stopped car, Manhunt fugitives and field
  contacts who run; armed runners too (before they could turn to fight) unless `armedTire = false`. The escape rules
  are unchanged.
- Spawn director, at the owner's request of 2026-10-19 ("make sure they dont spawn around the player make it be
  progressive", "i do not want them spawning in the ground or surronding the officers"): `Config.Spawning`. The
  server picks a mission's spawn points away from every officer (40 m, 15 m inside a building), never behind them,
  one wave from one side only (no ring, no pincer), and lets an objective's people appear only once an officer is
  within 150 m; a wave short of such points waits 20 s and may then come to 20 m, never closer.
- Shootouts use the spawn director (same request): every hostile_waves fight (Gang Shootout, Hostage Rescue, Drug Lab
  Raid, Gang Hideout Raid, the Weekly Boss) starts its first wave only once an officer is within 150 m of it and puts
  every hostile at least 40 m from the officers (15 m for the fights marked `indoor`: inside the Fleeca bank and in
  and around the raided lab or house), never behind them, one wave from one side, never two on one point; a short wave
  spawns the rest as points free up. A wave or boss still short 45 s after it began waiting while nobody of the fight
  is left standing is left out (`leaveOutAfter`, a warning in System → Problems), the one case where a scaled count
  shrinks (never before one of the fight's hostiles has appeared, so standing on the points first never skips a
  fight); a wave's 90 s to the next wave counts from its first hostile out; a location with no spawn points spawns
  nobody instead of using the start point.
- Staging ahead (same request): `Config.Spawning.stageAhead` (on) lets the engine place the next objective's people
  while the officers are still busy with the one before it, so they can already be in place (away from the officers)
  when it starts instead of appearing around them the moment it does. Only a mission step built for it stages (the
  raids, next item). What it placed goes with the run like everything else (a failure, the end or the last officer
  leaving removes it).
- Raids: the defenders are already inside before the breach (same request; before, the crew appeared the moment the
  breach completed, 2.6-10.5 m from the breach team): Drug Lab Raid and Gang Hideout Raid mark their fight `stage =
  true`, so wave 1 is placed while the officers drive in and stack up, through the spawn director (15 m or more from
  every officer at that moment, never behind them), calm and unarmed. They wake, armed and hostile, when the breach
  completes, or earlier when one of them is hurt or killed or an officer comes within `Config.Spawning.stageWakeRange`
  (12 m) of one of them. Officers nearer to a breach entry than to him do not wake him: the plan's 12 m alone would
  have woken the crew at the doors at nearly every raid location (most "inside" points are 2.6-12 m from the entries),
  so the fight would start before the breach. The rest of wave 1 (points too close when it was staged) comes when the
  fight starts, through the director as before; the scaled count and every other rule are unchanged.
- Hidden points first (same request): `Config.Spawning.preferHidden` (on) and `losTimeoutMs` (1500 ms), so
  hostiles appear behind buildings, containers or cars rather than in the open in front of you. When more points pass the director's
  rules than a wave needs, the server asks the games of the officers near the scene (up to 4, nearest first; with
  none within `activateRange`, the nearest one) which of those points they can see: each game probes a line of
  sight from the officer's head and from his camera to 1.0 m and 1.7 m above each point (the map, vehicles and
  objects block it; glass and people do not). A point is hidden only when every asked game answered and none of its
  lines is clear; hidden points are used first, and of two sides that hold as many points the one with more hidden
  points wins. The boss keeps his own spot first (the block marks it `first = true`). The server waits at most
  `losTimeoutMs`; a game that does not answer, answers nonsense or still owes an earlier answer makes every point
  count as seen (the order is then the mission's own, as before). After the wait the distance and "behind" rules
  run again from where the officers stand by then, so an officer who drove closer meanwhile never gets a point
  inside the distance. A call that cannot wait (outside a thread) does not ask.
- Ground probe (same request): `Config.Spawning.ground` (`pedAbove` -0.3 to 1.6 m, `vehicleAbove` -0.2 to 1.5 m,
  `propAbove` -0.1 to 0.5 m, `snapWithin` 3 m), `collisionTimeoutMs` (6000 ms) and `interiorTimeoutMs` (5000 ms):
  how a game judges one point against the ground: ok, put on the ground, under the ground, floating, no ground, in
  water, in a wall or inside not loaded. The ground is the highest surface under the point (looked for from 2 m and
  from 50 m over it), except that a person, a vehicle or an object under a low roof or the floor above (a trailer, a
  house room, a garage deck) stands on the floor under him when that is the smaller move, and the surface over him
  is reported as the roof. Used by the spawn point check and the placer; `enabled = false` does not switch it off for
  the spawn point check.
- The placer (same request; the spawn audit found Street Race Bust cars 1-2 m under the road, Gang Shootout points
  half a metre under the yard, and a far officer's game, with no ground loaded, simulating the new people):
  `Config.Spawning.place` (on). When the server asks (below), the game of an officer of the run puts a new mission
  person, vehicle or object on the ground at the server's point: the game that simulates it when that is an officer's of the run, else the officer of the run
  nearest to it. It keeps the entity frozen and the ground around it loaded, judges the point with the ground probe,
  then moves it straight up or down onto the ground there (it never picks another spot) and lets people and vehicles
  go (objects, and a person held cuffed, stay frozen), or leaves a bad point frozen; either way it tells the server
  once. A person seated in a car and anything attached go with what they are in or on.
- Every new mission entity waits frozen until an officer's game has placed it (same request; PLAN S10):
  `Config.Spawning.placeTimeoutMs` (8000 ms), `retries` (2), `onTimeout` (`'unfreeze'`). The server freezes every new
  person, vehicle and object of a mission as it makes it and asks for its placement; an officer's answer is taken only
  for that entity's current ask and only when the height is near its point. A bad point moves the same entity to
  another point the mission may use there (Gang Shootout, the raids, Hostage Rescue and the Weekly Boss: the spawn
  director's other good points of that wave, never one someone stands on, still away from the officers), at most
  `retries` times, then it is let go where it is (as before), with one console warning per bad point. When a game that
  is not an officer's near it takes a waiting entity over, the server freezes it there again. No answer within
  `placeTimeoutMs` while an officer is near: let go where it stands (or removed with `'delete'`), one warning. The
  director now also hands a block its spare points (ARCHITECTURE 5.10), and CP.Npc keeps or drops the ask with the
  bag (`CP.Npc.setPlace`).
- Warrant doors and scattering suspects (same request; PLAN S11; the spawn audit found Warrant Service's associates
  7-17 m beside the door from the start, on the knocking officer's flank, and the raids' 2-3 cooks or runners on one
  point, 1.25 m apart, the hideout's on the lieutenant's own spot): `Config.Spawning.associatesAtKnock` (on). The
  associates appear at the knock, through the spawn director: 15 m or more from every officer, never behind the one
  at the door, out of sight first, hostile at once. Every associate and scattering suspect gets a point of his own
  that no person, body or car of the run stands on; a scatter's suspects appear once an officer is within 150 m of
  their point, 40 m or more away. A list with fewer points than suspects says so once (System → Problems) and the
  others come out there once the one before has run off; after 20 s with no usable point the ring round the points
  (as before) and the escape routes' first points are tried too; still short 45 s later, once everyone who appeared
  is caught, the rest are left out so the objective ends. A door with no suspect point no longer puts him on the start
  marker. The suspect who surrenders is stood at the door step and put on the ground there by an officer's game
  (`CP.Spawn.again`). Grove Street's four associate points all lie on the flank of an officer at the door, so there
  the associate comes out once the officers step away from the door (to be checked in game with Check spawn points).
- Field contacts (same request; PLAN S12; the spawn audit found Suspicious Activity's people 4-17 m from the officer
  crossing the start circle, Parking Patrol's first car 5-7 m past it, and the returning driver / thief 14 m / 30 m
  from the car at a random angle, behind the officer as often as not): `Config.Spawning.contactRing` (25-40 m),
  `sceneOutside` (10 m), `sceneWaitMax` (45 s). A scene (Suspicious Activity's car and people, all at once) and each
  parked car of Parking Patrol (one by one along the street) appear once an officer is within 150 m of it and every
  officer is more than 35 m (the 25 m approach + 10 m) from it; an officer standing closer keeps it waiting (20 m
  after 20 s; after 45 s it appears anyway, one warning naming the mission and the place: move its start further
  out, which S19 does for the built-in scenes). The returning driver and the thief appear 25-40 m from the car on a
  footpath point the game of the officer at the car picks, in front of him and out of his sight first (ox_lib
  callback `crimson-police:client:spawn:walkIn`; no answer in 1.5 s: round the car, 25 m or more from every officer),
  wait for an officer's game to put them on the ground, then walk up to the car; the driver says and does what he
  does when he gets there. `enabled = false`: as before.
- Pursuit cars (same request, "i do not want them spawning in the ground or surronding the officers"; PLAN S13; the
  spawn audit found Traffic Enforcement's violator made on the road surface itself and the second violator at the
  first one's point, where an officer who chased the first one back up the road may stand):
  `Config.Spawning.vehicleLift` (0.5 m), `secondViolatorUpstream` (200 m). A car made on a point of the mission's road
  (Traffic Enforcement's violator, a race loop's waypoint, an open route's first point) is 0.5 m over the road there;
  the missions' own car points (already 0.5 m over the road) are used as written. The second violator comes 200 m up
  the road from the officer furthest up it (officers within 100 m of the road count; nobody on the road: from the
  observation point's spot, as the first), so it drives towards your officers wherever they worked the first stop,
  and its blip shows once it has passed where they stood. Every pursuit car (Traffic Enforcement, Pursuit Sim,
  Stolen Vehicle Takedown, Street Race Bust) goes through the spawn director: never within 40 m of an officer (it
  waits, or takes one of its next two slots further back; after 20 s 20 m is enough, never closer), then the placer,
  which may move it to those slots. A location without a start no longer puts a spawnOffset car 200 m from a
  player's position: one warning, and the car takes the objective's other points. `enabled = false`: as before.
- Armored Truck Escort (same request, "make sure they dont spawn around the player"; PLAN S14; the spawn audit found
  the truck made on the depot point itself, inside the car of an officer parked there, and the ambush cars 20-50 m from
  a lead car driving ahead of the truck, or behind the truck once it had passed the ambush point):
  `Config.Spawning.ambushAheadOnly` (on), and `vehicleLift` / `minDistance` for this mission too. The truck appears on
  the depot point 0.5 m over the road once no vehicle and no officer is within 6 m of it (the officers are told once to
  keep the start clear; after 20 s it takes the first free spot of four, 10 m apart, further along the route, never a
  taken one). Each ambush car is 0.5 m over the road where it stands (not one height for the whole wave), never within
  40 m of an officer (a lead car included), never on another vehicle, next to the truck or behind it: its slot slides
  further along the route, 15 m at a time, ahead of the truck. A wave with no slot left when the truck arrives (or held
  back by the spawn caps until then and finding none after) keeps the cars it has (none: it is left out, one
  warning), so the escort can end. `enabled = false`: as before.
- Hostage Rescue's hostages (same request, "make it be progressive"; PLAN S15; the spawn audit found the three
  hostages made at run start, before the fight even began): `Config.Spawning.hostagesAt` (`'objective'`),
  `hostagesWaitMax` (10 s). The hostages appear when their own objective starts (after the fight), on their points
  15 m or more from every officer (`minDistanceIndoor`, through the spawn director); an officer standing closer keeps
  them waiting, and after 10 s they appear on their points anyway with one warning naming the mission and the place.
  A location with no hostage points no longer puts them on the start point (one warning). `'runStart'` (or
  `enabled = false`): at run start, as before. The engine warns once per block whose `prepare` makes entities
  (ARCHITECTURE 4.4, block field `spawnsInPrepare`).
- Manhunt's fugitives and clues (same request, "make it be progressive", "make sure they dont spawn around the
  player"; PLAN S16; the spawn audit found every fugitive and clue made when the search started, 276-560 m from the
  officers, beyond the 424 m a player's game simulates). No new setting: `Config.Spawning` `activateRange` (150 m),
  `minDistance` (40 m), `waveDelayMax` (20 s), `hardMin` (20 m) and `preferHidden`. Nothing appears when the search
  starts. A fugitive appears on his hiding spot once an officer is within 150 m of it and every officer is 40 m or
  more from it, never closer; after 20 s of an officer standing closer he hides on another free hiding spot in the
  circle instead (one console line). A clue appears once an officer is within 150 m of it, 40 m or more from every
  officer, or closer where the officers' games say nobody can see it (20 m in sight after 20 s). What appeared stays;
  "Check clue" is offered only on a clue that is there. `enabled = false`: all at the search start, as before.
- Prisoner vans, tow trucks and coroner vans (same request, "make sure they dont spawn around the player"; PLAN S17;
  the spawn audit found the 60 s fallback putting the van on its parking point or on the scene with no player check,
  and a late van moved there by the server at the file's height): `Config.Custody.serviceClearance` (30 m, 10-100).
  A van is put on its parking point (the transport or coroner point, else the scene of the arrest) only while no
  player is within 30 m of it. A late van whose point an officer stands on drives on and is put there once he steps
  away; one that got no road point at all comes to a road point beside the scene (30-70 m from its point, picked by
  the nearest officer's game and checked by the server), or waits. A van put down waits frozen until an officer's game
  has put it on the ground, like every new mission vehicle. A road point an officer walked onto while the van waited
  for room is dropped and a new one asked. A tow truck that got no road point is never made inside the car next to
  you: the car fades out and counts as impounded (it used to sit there and never load it). `Config.Spawning.enabled
  = false`: the vans are put on their points as before.
- Mission Builder: armed spawns outside the arrival circle (same request, "surronding the officers"; PLAN S18; the
  Builder audit published a draft with 11 hostiles 31 m from a 60 m start with no error, and drew a 30 m keep-out ring
  inside the start circle): `Config.Builder.spawnMargin` (40 m, 0-150). In a new or edited custom mission every armed
  spawn point (a shootout's spawns, spawn sets and boss, escort ambush points, pursuit cars, warrant associates) must
  be outside the start circle plus the margin (2D, as officers arrive: 100 m from a 60 m start); the placement tool
  refuses a closer one as you aim ("Enemies must be at least 100 m from the start"), publishing refuses it with one
  message per location, and the Locations map and the in-world ring show that distance ("No enemies closer than
  100 m"). Hostages, suspects and field-contact people keep `minSpawnFromStart` (30 m). The points a built-in mission
  plays at its own start stay allowed in a duplicate of it (they play as in the built-in, kept away from your
  officers by the spawn director); a moved or new point follows the rule. A mission with a search area (its start is
  the search circle, entered anywhere) keeps the 30 m. A custom mission published before still loads, with one
  warning per location in Admin UI -> Missions -> Load result; publishing it again needs the points moved.
- Scene missions start further out (same request, "make sure they dont spawn around the player"; PLAN S19; the spawn
  audit found Suspicious Activity's people 4-17 m from an officer crossing the 40 m start circle, Parking Patrol's
  first car 5-7 m past it and Stolen Vehicle Takedown's car 18-24 m from him): the start circles of the built-in
  files are now Suspicious Activity 100 m (the car and every person 42 m or more from an officer at the edge),
  Illegal Parking Patrol 85 m (the first spot 38 m or more) and Stolen Vehicle Takedown 85 m (the car 43 m or more),
  so the GPS ends further out and the scene is already there, past the distance the spawn director waits for (the
  25 m approach plus `Config.Spawning.sceneOutside`, 35 m; for a car `Config.Spawning.minDistance`, 40 m), and
  Suspicious Activity's people still react only once an officer is within 25 m. Mission data only (the Mission
  Builder sets a circle of 20-150 m).
- No two people share one point (same request, "i do not want them spawning ... surronding the officers"; PLAN S21;
  the spawn audit found Gang Hideout Raid's runners on the lieutenant's own spot, Drug Lab Raid's cooks sharing one
  point and Prison Break's south-west fence with 6 points for 8 inmates): every Gang Hideout Raid location now has 4
  runner points on the lanes from the back of the house to its escape routes, every Drug Lab Raid lab 3 cook points
  (the hiding spot and 2 on the tracks towards the escape routes), and the south-west fence 8 inmate points, all on
  the road / track network at its height + 1 m, 3 m or more apart and never on the lieutenant or another spawn point,
  so nobody shares a point: each one appears on his own once the spawn director allows it (40 m or more from every
  officer, or 20 m after `waveDelayMax`; with your officers still at the lieutenant's body or the lab, the points
  closer to them wait until they move off). Each flees along the escape route that starts nearest where he appears
  (`Config.Flee.nearestRoute`, on), so nobody runs back across the site past your officers to a route on its other
  side. Check the points in game with Admin UI -> Testing -> Check spawn points.
- Check spawn points (owner request of 2026-10-19: "Double check all coordinates etc for every ped"):
  `Config.Testing.spawnCheck` (`enabled`, `sceneTimeoutMs` 8000 ms, `moveWithin` 150 m, `routes = false`). An
  admin's own game visits every point of a mission's locations (frozen, unseen and unhurt, back where he was at the
  end; nothing is spawned) and judges each by the ground probe; the server writes one console line per bad point,
  with its own coordinates. Each point is judged by what the mission puts there (a person, a vehicle by its model, an
  object, a marker or a route point), from each block's new `pointKinds` (ARCHITECTURE 7.1). New in SPEC (Admin test
  mode). Its screen: Admin UI → Testing → Check spawn points (scope, Start / Stop, progress, results, Teleport here
  with `Config.Testing.spawnCheck.teleport = true`, audited, and Copy report).

**Waiting for the owner's OK** (already in `docs/SPEC.md` and the code; each one is undone without a code change):

- Roles: the Roles Hard rule also counts a Qbox admin (the ace `admin`) as an admin while `Config.QboxAdmins` is
  `true`, which ships on. Undo: `Config.QboxAdmins = false` in config.lua.
- **D1** Point values are settings, marked "points value" (a confirm, and the flags webhook), and an admin's logged
  manual award may be **negative** (a deduction, never below 0 XP). Undo: `AdminControl.pointAdjust = false` stops
  adjustments; any point setting goes back to config.lua with **Reset** (or **Revert** in the history) in Settings.
- **D2** Corrections as bulk voids: an officer's, an operation's or a board window's runs can be voided as one batch
  (there is still no wipe). Undo: every batch has **Undo** in Officers → Corrections.
- **D4** Built-in missions edited in the Mission Builder, saved as an override under the same id in
  `missions/custom/overrides/`; only admins edit them. Undo: **Reset to original** per mission, or
  `AdminControl.editBuiltins = false` (every edit stops playing at once and is kept).
- **D5** Departments added, turned off and (when unused) deleted from the Admin UI; a turned-off department's
  unfinished pay still pays from its account. Undo: turn the department on again (Departments, or
  `Config.Departments.<key>.enabled`).
- **D6** Anti-farm overrides per officer (clear cooldowns, more completions today, another boss attempt, first-run
  bonus again, forgive streak days, add run time, treat a free abandon as a normal one), each with a daily or weekly
  limit counted from saved rows. Undo: set its limit in `Config.AdminControl` to 0.
- **D7** Money outside the normal flow: unlock a type's payout for supervisors (on); retry unfunded, pay the capped
  rest, pay a stuck payment again, re-pay forfeited cash, add funds, take back cash, manual cash and take back an item
  reward (all **off**; any admin turns one on in Settings by typing `ENABLE`, audited). Undo: switch it off again
  (`Config.Cash.allow*`, `Cash.restoreForfeited`, `Rewards.allowTakeBack`).
- **D9** Testing is optional for every mission and every role, built-in, custom and edited built-in alike. Undo:
  `Builder.requireTestToPublish = true` (supervisors then need a passed test; admins never do).
- **D10** Names for offences, commendation kinds, badges, bonuses and penalties (`Config.Labels`, English only).
  Undo: reset `Labels` in Settings.
- **D11** Move a re-created character's history to the player's new citizenid (same licence, logged). Undo: **Undo
  move**, or `Config.AdminControl.recordMove = false`.
- **D13** The maintenance lock during a storage copy, a storage switch or a backup restore (not a pause and not a
  switch: it always ends with your restart). Undo: none needed; it ends with the restart.
