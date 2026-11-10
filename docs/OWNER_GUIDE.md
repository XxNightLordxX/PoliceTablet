# Crimson-Police owner guide: every detail

The [README](../README.md) is the short owner's guide (install, admins, what ships off, commands, the Admin UI tour
and troubleshooting). This guide has everything else an owner may want to know: the supervisor permissions, the
settings worth changing, the optional extras, how each part plays, real suspects, go-live, updates and backups, more
console lines and the exports for other scripts. Each setting's own comment in `Crimson-Police/config/config.lua`
(shown in Admin UI → **Settings**) says what it does; this guide does not repeat every option.

## Contents

1. [Supervisors in detail](#1-supervisors-in-detail)
   - [1.1 The Supervisor UI layout](#11-the-supervisor-ui-layout)
   - [1.2 What supervisors may do](#12-what-supervisors-may-do)
   - [1.3 Mission Builder permissions](#13-mission-builder-permissions)
   - [1.4 What admins can do in the Admin UI](#14-what-admins-can-do-in-the-admin-ui)
2. [First things to set in config/config.lua](#2-first-things-to-set-in-configconfiglua)
   - [2.1 Departments and jobs](#21-departments-and-jobs)
   - [2.2 Supervisor grades](#22-supervisor-grades)
   - [2.3 Payouts](#23-payouts)
   - [2.4 Logos](#24-logos)
   - [2.5 Other settings you may want to change](#25-other-settings-you-may-want-to-change)
   - [2.6 Change any setting in game: the Settings screen](#26-change-any-setting-in-game-the-settings-screen)
   - [2.7 Turn missions and locations on or off](#27-turn-missions-and-locations-on-or-off)
   - [2.8 How hard NPCs fight back](#28-how-hard-npcs-fight-back)
   - [2.9 Baked in: one way to do each thing](#29-baked-in-one-way-to-do-each-thing)
3. [Optional extras](#3-optional-extras)
   - [3.1 The tablet item](#31-the-tablet-item)
   - [3.2 Mission desks](#32-mission-desks)
   - [3.3 Item rewards](#33-item-rewards)
   - [3.4 Profile pictures](#34-profile-pictures)
   - [3.5 Database off: the saves folder](#35-database-off-the-saves-folder)
   - [3.6 Discord webhooks](#36-discord-webhooks)
   - [3.7 Department logos](#37-department-logos)
   - [3.8 Paying from the department's bank account](#38-paying-from-the-departments-bank-account)
   - [3.9 Handcuff and evidence items](#39-handcuff-and-evidence-items)
   - [3.10 Adding a department](#310-adding-a-department)
   - [3.11 Field training (FTO)](#311-field-training-fto)
   - [3.12 Feature rewards: money and items for every feature](#312-feature-rewards-money-and-items-for-every-feature)
   - [3.13 Map markers: every part of a mission](#313-map-markers-every-part-of-a-mission)
4. [Settings to check in your other resources](#4-settings-to-check-in-your-other-resources)
   - [4.1 Locations and other scripts](#41-locations-and-other-scripts)
5. [How it plays](#5-how-it-plays)
   - [5.1 The officer's tablet](#51-the-officers-tablet)
   - [5.2 The supervisor's screens](#52-the-supervisors-screens)
   - [5.3 The admin panel](#53-the-admin-panel)
   - [5.4 The missions](#54-the-missions)
   - [5.5 Dispatch: mission calls](#55-dispatch-mission-calls)
   - [5.6 Police actions and custody](#56-police-actions-and-custody)
   - [5.7 Raids](#57-raids)
   - [5.8 XP and levels](#58-xp-and-levels)
   - [5.9 Leaderboards](#59-leaderboards)
   - [5.10 Department challenge and seasons](#510-department-challenge-and-seasons)
   - [5.11 Disputes, flags and suspensions](#511-disputes-flags-and-suspensions)
   - [5.12 Mission Builder](#512-mission-builder)
   - [5.13 Testing tools](#513-testing-tools)
   - [5.14 Rules to tell your officers](#514-rules-to-tell-your-officers)
   - [5.15 Full admin control](#515-full-admin-control)
      - [5.15.1 Officers, points and boards](#5151-officers-points-and-boards)
      - [5.15.2 Missions and the Mission Builder](#5152-missions-and-the-mission-builder)
      - [5.15.3 Live runs, units and anti-farm](#5153-live-runs-units-and-anti-farm)
      - [5.15.4 Payments, item rewards and department money](#5154-payments-item-rewards-and-department-money)
      - [5.15.5 System, departments and settings](#5155-system-departments-and-settings)
6. [Real suspects: live crimes and volunteers](#6-real-suspects-live-crimes-and-volunteers)
   - [6.1 Owner checklist](#61-owner-checklist)
   - [6.2 Rules for cases with real suspects](#62-rules-for-cases-with-real-suspects)
   - [6.3 What is built in for fairness](#63-what-is-built-in-for-fairness)
   - [6.4 When something does not happen](#64-when-something-does-not-happen)
   - [6.5 The criminal tablet](#65-the-criminal-tablet)
7. [Before go-live, updating and backups](#7-before-go-live-updating-and-backups)
   - [7.1 Before go-live checklist](#71-before-go-live-checklist)
   - [7.2 Updating](#72-updating)
   - [7.3 Backups](#73-backups)
8. [More console lines](#8-more-console-lines)
   - [8.1 Database and saves folder](#81-database-and-saves-folder)
   - [8.2 Config and departments](#82-config-and-departments)
   - [8.3 Missions and the Mission Builder](#83-missions-and-the-mission-builder)
   - [8.4 Payments, webhooks and other lines](#84-payments-webhooks-and-other-lines)
9. [Exports for other scripts](#9-exports-for-other-scripts)

---

## 1. Supervisors in detail

### 1.1 The Supervisor UI layout

**The Supervisor UI layout.** The sidebar is grouped by task under three headings: **People** (Department:
officers, give points, mission bans, Mission controls, Review Queue, calls and notices, field training),
**Missions** (Mission List, Live Missions, Cross-dept, Builder) and **Rewards** (Payouts). The dialogs **Give
points**, **Mission ban** and **Clear cooldown** open with the points, hours and reason last used on that tablet
(kept until Crimson-Police restarts or the player reconnects; a number outside the admin's current limits falls back
to the minimum), so a second award or ban in a row needs no typing; the server checks every value again. When a
supervisor or an admin approves or voids a flagged run or decides a dispute, every other supervisor of that
department who has the **Review Queue** open sees the updated queue at once. Two choices stay in `Config.Tablet`
(also in Admin UI -> Settings):

| Setting | What it does |
|---|---|
| `supervisorCompact` | `true` = a narrow strip of icons, each name on hover (the Review Queue count shows on the Department icon); shipped `false` |
| `supervisorLanding` | The screen the Supervisor UI opens on: `'first'` (shipped), `'report'` (Department on its **Officers** tab), `'review'` (Department on its **Review** tab) or `'live'`. A screen or tab the supervisor may not see falls back to the first screen. Once a screen is picked, the Supervisor UI keeps it until the player reconnects |

Only the layout changes: every screen keeps its permission, and a screen a supervisor may not see stays hidden (a
heading with nothing under it is not shown). Each control keeps showing its admin limits where it is used (for
example Give points shows the min to max points and today's use), and risky actions still ask first.

**One Department screen.** Everything a supervisor does for his department sits on **Supervisor UI -> Department**.
On top, **Today at a glance**: officers on duty, runs going, waiting for review and *Your controls used today*
(for example *43 / 103*); each number opens the tab (or Live Missions) where he acts on it, and it turns amber when
something waits or a day count is spent. Below it five tabs: **Officers** (the Department Report: each officer's
week; clicking an officer opens one side panel with his runs, his commendations and every action the supervisor may
take on him, **Give points**, **Mission ban** (or Lift), **Clear cooldown**, **Commend** and **Field training**, each
form opening right in the panel with the same limits, reasons, permission checks and audit rows as before),
**Controls** (Mission controls: each control shows the admin's limits and today's use on its own row, for example
*Admin limits: 1 to 50* and *Today: 40 of 100 used*, and the controls used from their own buttons, such as Give
points and Mission ban, are listed in one card with the same),
**Review** (the Review Queue), **Calls & notices** (the mission calls panel and the department notices) and
**Training** (field training). A tab shows only when the supervisor may use what is on it, with the same permission
as before, and the Review Queue count sits on Department. The old screens Department Report, Mission controls and
Review Queue are no sidebar entries any more (the limits and today's use always show inline on Controls).

Inside the screens, Mission controls and Review Queue share the Officer UI header (the screen name, its subtitle and
one help line) and its load states (spinner, error with Retry, "Could not refresh" over what was loaded last). Each
Mission controls group says what it is for in one line. Department notices are split into **Post a notice** and
**Running now (n)**, Field training lists its **Pairings (n)**. Ending a notice or a field training takes two
clicks; every Mission control change, Approve, Void and Reject asks for a reason, as before.

### 1.2 What supervisors may do

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
| `missionControls` | `false` | Change the Mission controls an admin switched on (below) | Their department only, inside the admin's limits |

Supervisors can always see the Mission List, Live Missions and the Department screen's **Officers** and **Training**
tabs for their own department. The other screens and tabs hide when their switch is `false`: **Cross-Department
Mission** (`launchCrossDept`), **Payouts** (`setTypePayout`), **Mission Builder** (`builderEdit`), Department ->
**Review** (when `reviewFlagged` and `handleDisputes` are both `false`) and Department -> **Calls & notices** (when
`missionCalls` is `false` and no Mission control is open to him).

Related settings: `Config.Payouts.supervisorRange` (`{ 0.5, 2.0 }` = 50–200%), `Config.Payouts.supervisorCooldown`
(`1800` seconds), `Config.Commendations.crossDepartment` (`false`; `true` lets supervisors commend other departments),
`Config.Commendations.perSupervisorPerDay` (`3`).

**Mission controls** let a department's supervisors change a few mission rules for their own department, inside limits
you set. They are **off on install** except the seven server-wide cooldown controls below (cooldownScale,
abandonCooldown, noRepeat, hourlyCap, dailyCap, happyHour, clearCooldown): nothing changes until you switch them on.
You set them in Admin UI → **Permissions** → **Mission controls** (below); supervisors change them in Supervisor UI →
**Department** → **Controls** (below).

- **Mission cooldowns** (on when you install): any department's supervisor may change them, without
  the master switch, and a change counts for **every department** (server-wide):
  - `cooldownScale = { on = true, min = 0, max = 2 }`: x every mission's cooldown, one number per mission type
    (`0.5` = half, `0` = no mission cooldown for that type, `2` = double). `min`/`max` may be 0-4.
  - `abandonCooldown = { on = true, min = 0, max = 900 }`: the abandon cooldown in seconds (normally
    `Config.Limits.abandonCooldown`, `300`), for quits, going down, leaving duty and the like.
  - Both apply at once to cooldowns already running, also after a restart, and go back to config.lua when reset or
    when you switch the control off (`on = false`). The supervisor who shortened a cooldown keeps the config.lua one
    himself (and so does any unit he is in). An admin's Quick edit of a mission's cooldown also applies at once.
  - The supervisor Mission list shows a changed cooldown as `20 min → 10 min`; Admin UI → Officers → Today & cooldowns
    shows `(cooldown x0.5)` next to the mission.
  - `noRepeat = { on = true }`: `false` switches the no-repeat rule (`Config.Draw.avoidLast`) off, so an officer
    or unit may get the same mission twice in a row. The board still never names a mission.
  - `hourlyCap = { on = true, min = 1, max = 16 }`: completed missions per officer per hour (normally
    `Config.Limits.maxCompletionsHour`, `8`). The board lock, mission calls and the Weekly Boss card use it.
  - `dailyCap = { on = true, min = 0, max = 40 }`: completed missions per officer per day (normally
    `Config.Limits.maxCompletionsDay`, `0` = no cap); `0` here also means no cap.
  - These three count for every department too, and the self rule applies: the supervisor who switched the
    no-repeat rule off or raised a cap keeps the config.lua rule himself (and so does any unit he is in).
  - `happyHour = { on = true, min = 5, max = 30 }` (happy hour): a supervisor picks the minutes (here 5 to 30) and
    presses **Start happy hour** in Supervisor UI → Mission controls. Until it ends no mission has a cooldown for
    anyone on the server, and with the box ticked the no-repeat rule is off too. The abandon cooldown, the hourly and
    daily caps and the cash rules stay. When it ends every officer's cooldowns count again from when his runs really
    ended. The supervisor who started it keeps his own cooldowns (and so does any unit he is in). A restart keeps it.
    Officers see a banner on Home and the Mission Board ("Happy hour: no mission cooldowns for 14:32, set by Sgt
    Doe"); admins see a chip with **End now** in Admin UI → Live. `Config.MissionControls.happyHourPerDay` (`1`):
    happy hours a supervisor may start a day (`0` = none); admins may start more, one at a time.
  - `clearCooldown = { on = true }` (**Clear cooldown**, on when you install: it is a cooldown control): in Supervisor
    UI → **Department** → **Officers** a supervisor opens an officer and presses **Clear cooldown**. He sees the
    officer's mission type and mission cooldowns with the time left and clears one at a time, with a reason. Any
    department's officer (a cooldown change is server-wide), never his own character, never while the officer is on a
    run, and each officer at most `Config.AdminControl.cooldownClearsPerDay` (`3`) clears a day by all staff together.
    `Config.MissionControls.clearCooldownPerDay` (`5`): clears one supervisor may make a day. The officer gets a
    toast; the clear is in the audit log and in Admin UI → Officers → Today & cooldowns.

- **+ minutes on a live mission** (`addRunTime = { on = false, min = 1, max = 5 }`, off when you install, under the
  master switch): in Supervisor UI → **Live Missions** a supervisor presses **+ minutes** on a running mission of his
  department (never one he is on) and adds `min` to `max` minutes per click, with a reason. Everyone on it is told and
  the HUD timer shows the new time. The fast-finish bonus is still judged on the original time limit.
  `Config.MissionControls.addRunTimeMax` (`300` seconds) caps what may be added to one mission in all, an admin's
  additions counted, never above `Config.AdminControl.runTimeAddMax`; `Config.MissionControls.addRunTimePerDay` (`10`):
  additions one supervisor may make a day.

- **In a run** (per department, off when you install, under the master switch). A supervisor sets them for
  his own department; each is read for the leader (and his unit) when the run is accepted and kept for that run, so a
  change never moves a run already going:
  - `startTimeout = { on = false, min = 300, max = 900 }` (**Time to reach the start**, seconds): replaces
    `Config.Limits.startTimeout` and the mission's own start timeout for runs his department leads. The HUD shows the
    new time after the accept (900 = 15:00).
  - `readyCheck = { on = false, min = 10, max = 40, canTurnOff = false }` (**Ready check**, seconds to answer): replaces
    `Config.Units.readyTimeout` for units his department leads. With `canTurnOff = true` (Admin UI → Permissions →
    Mission controls, "Supervisors may switch the ready check off") he may also switch the ready check off (0).
  - `timeLimit = { on = false, min = 1.0, max = 1.25 }` (**Mission time limit**, x the mission's time limit): the run
    lasts longer; the fast-finish bonus is still judged on the unscaled limit, so points never move.
  - `idleCheck = { on = false, min = 60, max = 180 }` (**Idle check**, seconds): officers who never reached the start
    are removed this long after the run starts (`Config.AntiCheat.idleCheck`). Stricter only: never above the config
    value, so it can never become a free way out of a run.
  - `difficulty = { on = false, presets = { 'easy', 'normal' } }` (**NPC difficulty**): he picks one of the
    listed `Config.NpcDifficulty` presets (easy, normal, hard, custom; Admin UI → Permissions → Mission controls has a
    box per preset) for runs his department leads: NPC health, aim, surrender and how long runners keep running. The
    `Config.NpcCombat` limits still apply on top, and points and cash never change. A supervisor who picks an easier
    preset keeps the config one himself (the self rule).
  - `unitSize = { on = false, min = 2, max = 4 }` (**Largest unit**): the most officers a unit led by his
    department may have; invites past it, joining a full unit and accepting a mission with a larger unit are refused.
    Never above `Config.Limits.maxUnitSize`.

- **Mission Board** (per department, off when you install, under the master switch). A supervisor sets them
  for his own department in Supervisor UI → Mission controls → Mission Board:
  - `types = { on = false }` (**Mission types on the board**): a switch per mission type and, folded under it, per
    mission. A type switched off shows locked on his officers' boards ("Off for SAST by command"); they cannot accept
    it or claim its mission calls, and neither can a unit with one of them in it. Officers of other departments still
    take it. A single mission switched off is never drawn for his officers. It stays until switched back on (it is
    not a timed pause); at least one type always stays on; the Weekly Boss is never affected.
  - `featuredType = { on = false }` (**Recommended type**): one mission type his officers see as **Recommended by
    command**, right after their own favourite types. Points and pay never change. Reset to recommend none.

- **Mission ban** (`missionBan = { on = false, min = 1, max = 24 }`, off when you install, under the master switch):
  in Supervisor UI → **Department** → **Officers** a supervisor opens an officer of his own department and presses
  **Mission ban**: hours (here 1 to 24) and a reason. Only an officer who is online, of a lower grade than his, never
  himself. Until it ends the officer cannot accept from the Mission Board (nor can a unit he is in), claim a mission
  call or join a Cross-Department Mission; his board shows "Mission ban until 18:40 (by Sergeant Doe)" with every card
  locked. The tablet stays usable (it is not a suspension; suspensions stay admin-only) and a mission he is already on
  goes on. The supervisor who set it may **Lift mission ban** early from the same dialog; an admin lifts any ban in
  Admin UI → Officers → **Today & cooldowns**. The officer gets a toast; the ban and the lift are in the audit log
  under flags (posted to `cp_webhook_flags`), and a restart keeps the ban. `Config.MissionControls.missionBanPerDay`
  (`3`): bans one supervisor may set a day.

- **Calls** (per department, off when you install, under the master switch). A supervisor sets them for
  his own department in Supervisor UI → Mission controls → Calls:
  - `callLane = { on = false, min = 120, max = 600 }` (**Department call lane**): his department's own mission calls
    next to the server's. He picks the gap between two lane calls (a range inside `min` to `max` seconds), how many
    may be open at once (up to `Config.MissionControls.callLaneMaxOpen`, `2`), the areas (none picked = every area)
    and a weight 0-10 per mission type of `Config.MissionCalls.types`. Only his department's officers get the pop-up,
    see the call on Dispatch (tagged "SAST call") and may claim it; a unit with an officer of another department
    cannot, and neither can the unit of the supervisor who set the lane. Lane calls count against
    `Config.MissionCalls.maxOpen`; the server's own calls are not changed. The staff mission calls panel lists
    the lane.
  - `staffCallWait = { on = false, min = 60, max = 120 }` (**Wait between staff calls**): seconds his department's
    supervisors wait between two mission calls they create, instead of `Config.MissionCalls.staffCooldown`. The one
    who shortens it keeps the config wait for himself.

- **Department** (per department, off when you install, under the master switch):
  - `notices = { on = false }` (**Department notices**): in Supervisor UI → Mission controls a supervisor posts a
    short notice for his own department only (1 to 30 days). Its officers see it on Home → **Announcements**; other
    departments never do. Up to `Config.MissionControls.noticeMaxLength` (`280`) characters, the banned-word list
    applies, at most `Config.MissionControls.noticesPerDay` (`5`) a supervisor a day (admins any) and at most 5
    running per department (they do not count against the 5 staff notices an admin may run). Any supervisor of the
    department may **End** one early. Every post and end is in the audit log; admins see and remove them with the
    staff notices (Leaderboards → Recognition, posted by `sup:<citizenid>`).
  - `crossDept = { on = false }` (**Cross-Department participation**): a supervisor keeps his department's officers
    out of Cross-Department Missions (their Join is refused and the card says why) or caps how many places they may
    take in one (0 = no cap, at most `Config.CrossDept.maxParticipants`). It applies to him too. Every department's
    board still shows only the running operation (the lock), and the wait between launches stays server-wide.

- **Leaderboard and review** (per department, off when you install, under the master switch):
  - `boards = { on = false }` (**Leaderboard visibility**): a supervisor picks whether officers of other departments
    see his department's officers by name or by callsign only (on the Leaderboard, on their profiles and in Home's
    top 3; the picture is hidden too), and which **Rank by** tabs his own officers see (from
    `Config.Leaderboard.metrics`; Points always stays). A tab change shows the next time an officer opens the tablet.
    Presentation only: the counts, the Department Challenge and the admin boards never change.
  - `reviewRules = { on = false }` (**Review rules**, stricter only): with **A Void needs a second supervisor** on, a
    supervisor's **Void** of a flagged run of his department only marks it pending ("Void pending (name)" in Review);
    a second supervisor of that department confirms it (the same supervisor, another character of his, or a
    supervisor of another department cannot). A server restart clears a pending Void (it is voided only by two).
    Flags of the kinds he ticks (for example "Ran a suspect over") leave the supervisors' Review queue: only admins
    approve or void them (Admin UI → Review → Flagged runs). Admins always void at once. The anti-cheat flag
    triggers (`Config.AntiCheat`) are never relaxed.

- **Twists** (per department, off when you install, under the master switch):
  - `twists = { on = false }` (**Twists offered**): a supervisor picks which of the twists you enabled in
    `Config.Events.twists` his department's leaders are offered on the accept step (Mission Board and mission call
    claims), and which of them start ticked. The accept step follows the department of the unit's leader; a twist
    his department does not offer is refused ("Your department does not offer that twist."). Other departments keep
    every twist. Each twist's bonus stays as `Config.Events.twists` sets it. Read when the run is accepted, so a
    change never moves a run already going.

- **Cash bonuses** (per department, off when you install, under the master switch). A supervisor moves cash
  only inside the min and max you set; with the shipped `min = 1.0, max = 1.0` nothing moves even when switched on, so
  open the max first (for example `max = 1.25`). Points never change. Both are paid only on a completed run, never on
  test runs, Cross-Department runs or the Weekly Boss, and `Config.Cash.dailyCap` still applies (it ships at 0, no cap).
  - `happyHourCash = { on = false, min = 1.0, max = 1.0 }` (**Happy hour cash**): x the cash of a run his department
    leads that was accepted while a happy hour ran. The bonus is fixed at the accept, so the end of the hour never
    cuts a live run; the one who started the happy hour (and a unit he is in) gets none. The result card shows it
    (for example `x1.20 happy hour`).
  - `twistCash = { on = false, min = 1.0, max = 1.0 }` (**Twist cash**): x each twist's cash (`Config.Events.twists`)
    on runs his department leads, read at the accept; the accept step shows the raised bonus. All chosen twists
    together still stop at `Config.Events.twistMaxCash`.
- **Points bonuses** (per department, off when you install, under the master switch). Like the cash
  bonuses, a supervisor moves points only inside the min and max you set; the shipped `min = 1.0, max = 1.0` moves
  nothing even when switched on, so open the max first (for example `max = 1.25`). Only completed runs get them, never
  test runs, Cross-Department runs or the Weekly Boss. Runs with them count normally on the boards and in the contest.
  - `happyHourPoints = { on = false, min = 1.0, max = 1.0 }` (**Happy hour points**): x the final points of a run his
    department leads that was accepted while a happy hour ran (applied after the points cap, like the Type of the
    Day). Fixed at the accept, so the end of the hour never cuts a live run; the one who started the happy hour (and a
    unit he is in) gets none. The result card and the Profile run card show a **Happy hour** line (for example `x1.2`).
  - `twistPoints = { on = false, min = 1.0, max = 1.0 }` (**Twist points**): x each twist's points share
    (`Config.Events.twists[k].points`) on runs his department leads, read at the accept; the accept step shows the
    raised share. All chosen twists together still stop at `Config.Events.twistMaxPoints`.
- **Type of the Day** (per department, off when you install, under the master switch):
  `typeOfTheDay = { on = false }`. A supervisor picks one mission type **for tomorrow** (never today, so nobody times
  it to a run), at most once a day for his department (admins may correct it). Tomorrow his department's officers earn
  the Type of the Day points on that type instead of the server's type; other departments keep the server's type. The
  multiplier stays yours (`Config.Events.todMultiplier`), points only, cash never doubles. The pick never doubles the
  setter's own runs or a unit he is in (they keep the server's type). Switching the control off drops the pick at once;
  a restart keeps it (it is read back from the audit log). The Mission Board, Home, Dispatch, the run screen and the
  scoring all use the officer's department's type.
- **Department goals** (per department, off when you install, under the master switch):
  `goals = { on = false, min = 1, max = 5 }`. A supervisor picks which of your daily and weekly goals
  (`Config.Goals.daily`, `Config.Goals.weekly`) his department's officers draw theirs from: `min` to `max` of each
  list, or none (every goal). The pick counts **from the next weekly reset**, so no goal an officer is working on
  changes; a second change in the same week waits for the week after. The points stay yours
  (`Config.Goals.dailyPoints`, `weeklyPoints`); other departments and the supervisor himself keep your whole lists.
  A goal you remove or switch off later is left out of the pick (none left = every goal). Switching the control off
  or **Back to config** goes back to every goal at once; a goal already rewarded this period never pays twice.
- **Push a chosen mission** (per department, off when you install, under the master switch):
  `pushMission = { on = false }`. In **Page a unit** (Live Missions) the supervisor may pick one mission of the call's
  type instead of **Any (drawn at random)**, for a unit of his own department (never his own unit). Only that unit gets
  the call, for its whole offer, and only that unit sees the mission's name ("Mission: ..." on Dispatch); its leader
  accepts or declines it. Every accept rule stays (cooldowns, caps, unit size, missions switched off for the
  department, a start in the area named); only the random pick of the mission is skipped. A decline, a refused accept
  or a failed ready check ends the call (the supervisor is told), an abandoned run is never re-dispatched, and a push
  never earns rapid response. `Config.MissionControls.pushMissionPerDay` (`5`): pushes one supervisor may make a day
  (admins any). Every push is in the audit log (**Mission pushed to a unit**) with the mission.
- **Give points** (per department, off when you install, under the master switch):
  `awardPoints = { on = false, min = 1, max = 50 }`. In **Department** → **Officers** the officer's dialog gets a **Give
  points** button: the supervisor gives `min` to `max` points at a time to an officer of his own department (also one
  who is offline), never to himself or another character on his license (license: and license2:), always with a
  reason. It is the same logged manual award as Admin UI → **Give or take points** (a new row, shown in the
  officer's history like an admin's award; only an admin can undo it by voiding the row), so your
  `Config.AdminControl` rules apply too: `pointAdjust = false` stops it, `adjustDailyLimit` and the typed confirmation
  at `adjustConfirmAbove` count for supervisors as well. `Config.MissionControls.awardPointsPerDay` (`100`): points
  one supervisor may give a day in all (`0` = no limit; admins any). Every award is in the audit log (**Manual
  award**, role supervisor) with the reason.

- To switch them on: set `Config.Permissions.supervisor.missionControls = true` (the master switch; Admin UI →
  **Permissions**), then switch on each control you want in `Config.MissionControls.controls`, with the only values a
  supervisor may pick: `<control> = { on = true, min = ..., max = ... }`. Switching either off again brings back
  the config.lua rule at once.
- A department can have its own limits: `Config.Departments.<key>.missionControls = { <control> = { min = ..., max =
  ... } }`.
- `Config.MissionControls.grants` limits it to some grades, like the teleport grant: `sast = { minGrade = 4 }`.
  Empty = every supervisor.
- `Config.MissionControls.changeWait` (`300` seconds): how often one control may change in one department.
  Admins are not held to it.
- `Config.MissionControls.selfExempt` (`true`): a control that makes a rule easier never applies to the supervisor
  who set it, his other characters, or a unit he is in.
- Every change needs a reason and is in the audit log (who, old and new value). Admins can change or reset any
  department's controls, still inside the limits.
- **In game: Admin UI → Permissions → Mission controls.** The master switch stays the **Mission controls** row of the
  supervisor table. The card under it has one row per control: its admin switch and the **Lowest** and **Highest**
  value a supervisor may pick (both save `Config.MissionControls.controls`), what applies now (the value, the
  config.lua value, who changed it and when, how long it still runs) and **Reset** (back to config.lua, with a reason).
  A control that is not server-wide also has **Departments**: per department its own limits (saved as
  `Config.Departments.<key>.missionControls`; a department added in game uses the shared ones), what applies there
  and **Reset**. **Who may use them** sets `Config.MissionControls.grants` per department: every supervisor, from a
  grade, or these grades.

### 1.3 Mission Builder permissions

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
- **Teleport to a point.** On the Locations step, the start row and every row of the point list have **Teleport**:
  it puts you on the ground at that saved point (built-in missions too), so you can look at a spot without driving
  there. Admins always have it. Nobody else does until you grant it in `Config.Permissions.builderTeleport`, by
  department and grade: `sast = { minGrade = 4 }` (grade 4 and up) or `bcso = { grades = { 3, 5 } }` (only those).
  In game, Admin UI → **Permissions** → **Builder teleport** sets the same thing: per department pick **Off
  (admins only)**, **From grade** (a grade of that department's Qbox jobs) or **These grades** (tick them), then
  **Save**. It saves over config.lua like any setting and is in the audit log.
  The tablet sends only which point; the server checks the grant, reads the saved position, refuses in the arena,
  on a run or while down, and writes `builderTeleport` in the audit log. `Config.Builder.teleport = false` removes
  the button for everyone.

- **Extra grants: a power for people who are not supervisors.** Admin UI → **Permissions** → **Extra grants** lists
  every supervisor power (review, disputes, Mission controls, builder, mission calls, commendations and the rest), plus
  **Builder teleport**, **Field training** (pair and unpair) and **Criminal tablet** (who may use the criminal tablet
  while `Config.CriminalTablet.access = 'granted'`, [6.5](#65-the-criminal-tablet); it never adds a Supervisor UI
  screen). Click **Edit** on one and give it to a department
  from a grade (or only some grades), to a Qbox gang from a grade, or to one character by citizen ID. Each change
  saves the setting `Config.Permissions.grants`, is checked by the server and is in the audit log; it works at once.
  An officer with a grant gets the **Supervisor UI** button with only the screens of his powers, always for his own
  department. A power switched off above stays off for everyone, admin-only actions can never be granted, and admins
  still come only from server.cfg and `Config.AdminAce` / `Config.QboxAdmins`. Shipped empty: only supervisors.

### 1.4 What admins can do in the Admin UI

**What admins can do now.** Everything below is a button in `/CrimsonPoliceAdmin`, needs a reason, and goes into the
audit log. [5.15](#515-full-admin-control) explains each one.

- **Officers**: add or take away points, check and fix XP, void or restore runs in bulk (every batch has **Undo**),
  retire and unretire an officer, move a record to a player's new character, grant or revoke badges, fix a streak,
  mark a goal done, reset a picture or bio, suspend until an exact time, post a staff notice on Home
  ([5.15.1](#5151-officers-points-and-boards)).
- **Boards and seasons**: rank by any number, look at past weeks and months, recount a week and post it again,
  rename a season, plan its end, end it, reopen it within 24 hours, pick next week's bounty
  ([5.15.1](#5151-officers-points-and-boards)).
- **Missions**: edit **any built-in mission** in the Mission Builder (it stays under the same mission id, and
  **Reset to original** brings the shipped one back), quick-edit cooldowns, timers, NPCs, cars and weapons, delete
  and bring back, change owner, import and copy as Lua, see mission, operation and dispatch history and stats, and
  switch any mission or location on or off ([5.15.2](#5152-missions-and-the-mission-builder),
  [2.7](#27-turn-missions-and-locations-on-or-off)). No mission ever needs a test.
- **Live runs**: recall, end or add time to any run, end someone else's test, remove a member from a unit or disband
  it; per officer clear cooldowns, allow more runs today or another boss attempt; change today's Type of the Day
  ([5.15.3](#5153-live-runs-units-and-anti-farm)).
- **Money**: the Payments ledger with totals and a CSV export, **Pay now**, resolve a payment stuck in "paying",
  cancel or forfeit a payment, adjust every payout at once, each department's funds. The tools that move money
  outside the normal flow are built but **ship off**; you switch one on in Settings by typing `ENABLE`
  ([5.15.4](#5154-payments-item-rewards-and-department-money)).
- **System**: add, edit, turn off and delete departments, place desks, upload logos, copy and switch the storage,
  back up and restore, see which webhooks are on, read recent problems, check the other resources, run the nightly
  clean-up now, and revert or export your settings ([5.15.5](#5155-system-departments-and-settings)).

---

## 2. First things to set in config/config.lua

Every setting lives in `Crimson-Police/config/config.lua`. Each line has a short note. **You never have to edit
this file:** every setting below can be changed in game by an admin in Admin UI → **Settings**
([2.6](#26-change-any-setting-in-game-the-settings-screen)), with the same note shown next to it. If you do edit the
file, restart Crimson-Police after a change (`restart Crimson-Police` in the console). If `config.lua` has a typing
mistake, a red line says so when it starts (see [8.2](#82-config-and-departments)).

`config.lua` is laid out like the Admin UI, in six parts, each with a `PART n` heading in the file. Inside each part,
every block keeps its own `====` banner, and Admin UI → **Settings** → **All settings** lists the sections in this
same order. A block that matters to two parts has a `See also` line. The file opens with a **CONTENTS** list of the
six parts and the blocks in each, and every part heading ends with a `Usually changed here:` line naming the settings
owners change most. Every key has a note with its unit and the values it takes. In a list whose entries all have the
same fields (the bonuses, the map marker kinds, the departments, the custody truths), lines such as
`-- value: the points ...` above the list explain each field once for every entry, and Settings shows that line as the
field's description.

1. **General**: `Debug`, `Locale`, `Database`, `Format`, `Tablet` (with the admins, `AdminUi` and `AdminTheme`),
   `Permissions`, `AdminControl`, `Departments` and `Labels` (names).
2. **NPC missions**: mission types, stars, team size scaling, spawning, NPC behaviour, the route, map markers, the
   draw, mission calls, real calls, alerts, downed officers, custody, decisions, events, built-in mission tweaks and
   the Mission Builder.
3. **Player vs police**: `RealSuspects`, `LiveCrime`, `Volunteers` and `CriminalTablet`.
4. **Police teamwork**: units, Cross-Department Missions, supervisor mission controls, field training, the
   leaderboard, the department challenge and officer profiles.
5. **Economy and rewards**: cash, payout editing, disputes, scoring, XP, badges, goals, bonuses, item rewards and
   feature rewards.
6. **System**: run limits (`Config.Limits`), anti-exploit, the daily reset, admin test mode, retention, backups and
   the webhook convars.

### 2.1 Departments and jobs

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
  (see [README 3.3](../README.md#33-check-your-police-jobs)). A job may only be in one department.
- `label` and `short`: the name and tag players see.
- `theme`: the tablet colours, as 6-digit hex colours like `#1f4e8c`. `personalAccents` inside `theme` lists the
  accent colours officers may pick for their own tablet (some unlock at a level).
- `logo`: see [2.4](#24-logos).
- To add a department (BCSO, for example), see [3.10](#310-adding-a-department).

### 2.2 Supervisor grades

Set `supervisorGrade` in each department to the grade number where supervisors start. Section
[README 4.3](../README.md#43-supervisors) shows how to find the number. The shipped value is `3` in both departments.

### 2.3 Payouts

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
  bank account, see [3.8](#38-paying-from-the-departments-bank-account)); `minPayout` and `maxPayout` limit every
  payout set in game (0 to 25,000); `dailyCap` = most cash per officer per day (0 = no cap).
- Admins can also change payouts in game (Admin UI → **Money** → **Pay rates**, or `/CrimsonPoliceAdmin payout type
  patrol 300 New economy`). A payout set in game wins over `config.lua`. An admin can go back to the `config.lua`
  value with `/CrimsonPoliceAdmin payout type patrol clear Back to config`. **Let supervisors change it again** and
  **Adjust all** are in [5.15.4](#5154-payments-item-rewards-and-department-money).
- The other `Config.Cash` keys are the admin money tools (`allowPayAgain`, `allowUnfundedRetry`, `allowCapTopUp`,
  `restoreForfeited`, `allowClawback`, `allowManualCash`, `allowAddFunds`, all `false`), their limits (`addFundsMax`,
  `manualDailyLimit`) and `lowBalanceWarn`. See [5.15.4](#5154-payments-item-rewards-and-department-money).

### 2.4 Logos

Each department shows its logo in the tablet header and faintly behind every screen. The shipped `sast.png` and
`fib.png` in `Crimson-Police/logos/` are placeholders. Put your own file there with the same name, or change
`logo.file`, then restart Crimson-Police. Section [3.7](#37-department-logos) has the details.

### 2.5 Other settings you may want to change

Everything else works as shipped. These are the ones owners change most:

**General**

| Setting | What it does |
|---|---|
| `Config.Format.currency` | The money symbol (`'$'`) |
| `Config.Locale` | Leave it `'en'`: English is the only language shipped |
| `Config.Tablet.keybind`, `dispatchKey`, `readyKey`, `contactKey` | Default keys for new players (`''` = none). See [README 6.2](../README.md#62-keys) |
| `Config.Tablet.access` | Which ways open the tablet: `command`, `keybind`, `item`, `desk`, and `requireItem` |

**NPC missions**

| Setting | What it does |
|---|---|
| `Config.DisabledMissions` | Missions to turn off, e.g. `{ 'prison_break' }`. Easier: the on/off switches in Admin UI → **Missions** ([2.7](#27-turn-missions-and-locations-on-or-off)) |
| `Config.DisabledLocations` | Single locations to turn off, by mission: `{ prison_break = { 'North gate' } }`. Also switched in Admin UI → **Missions** |
| `Config.MissionTweaks` | Change a built-in mission's cooldown or time limits, switch off some of its locations, or change its NPC models, cars or weapons, without editing its file |
| `Config.Spawning` | Where a mission's people may appear (the spawn director): never closer than `minDistance` (40 m) to any officer, `minDistanceIndoor` (15 m) inside a building; never behind your officers (more than `behindAngle`, 110 degrees, off an officer's line to the scene, whichever side he came in from, counted for officers within `activateRange`); one wave always from one side (a `maxSpread` slice of 150 degrees, so never all around them); and an objective's people only once an officer is within `activateRange` (150 m). A wave that finds too few such points spawns what it can and the rest later (as your officers move or hostiles fall), waits up to `waveDelayMax` (20 s), then may use points down to `hardMin` (20 m) away, never closer. If a wave still cannot be placed `leaveOutAfter` (45 s) after it began waiting and nobody of the fight is left standing, the hostiles it could not place are left out so the fight can end (never before the fight's first hostile appeared; 0 = wait for ever). Used by every shootout: Gang Shootout and the Weekly Boss, and at the indoor distance Hostage Rescue and the raids' fights. `log` prints a console line for each point it skips, by its name in the mission file (`spawns[7] skipped: 2 m from <officer>`, with `Config.Debug`) and a warning when a wave had to come closer or left someone out. `stageAhead` (on) lets a mission place the next objective's people ahead of time, while your officers are still busy with the one before it, so they are already in place when it starts instead of popping up around the officers the moment it does (the raids use it; off = everyone appears when their objective starts). `stageWakeRange` (12 m): a raid's crew waits calm and unarmed before the breach and wakes, armed, when the fight starts, or earlier when one of them is hurt or killed or an officer comes this close to one of them (officers at the breach entries, nearer to an entry than to him, do not count; 0 = only a hurt one wakes them). `associatesAtKnock` (on): Warrant Service's armed associates come out only when an officer knocks, 15 m or more from every officer, out of sight first and never behind the officer at the door, instead of waiting beside the door from the start (off = they wait at their points from the start, as before). Every associate and every scattering suspect (Prison Break, the raids' cooks and runners) gets a point of his own, never on another person, a body or a car; a list with too few points is said once in System → Problems and the others come out there one after another. `leaveOutAfter` covers them too: associates or scattering suspects still short of points 45 s after they began waiting, once someone of them has appeared and every one who did is caught or dead, are left out (one warning) so the objective can end (0 = wait for ever). `sceneOutside` (10 m): a field contact scene (Suspicious Activity's car and people, all at once) and each parked car of Parking Patrol appear once an officer is within `activateRange` of it while every officer is further than the mission's approach distance (25 m) plus this from it, so they are there before you are on top of them; an officer standing closer keeps it waiting (`hardMin` after `waveDelayMax`), and `sceneWaitMax` (45 s; 0 = for ever) after it began waiting it appears anyway with one console warning naming the mission and the place (move that start further out). `hostagesAt` (`'objective'`): Hostage Rescue's hostages appear when their own objective starts (after the fight), on their points `minDistanceIndoor` (15 m) or more from every officer; an officer standing closer keeps them waiting, and `hostagesWaitMax` (10 s; 0 = until the officers step back) after that they appear on their points anyway with one console warning (they are tied up and unarmed, and the rescue cannot go on without them); `'runStart'` = at run start, before the fight, as before. Manhunt: nothing appears when the search starts; each fugitive appears on his hiding spot once an officer is within `activateRange` of it and every officer is `minDistance` (40 m) or more from it, never closer (an officer standing closer keeps him waiting, and after `waveDelayMax` he hides on another free hiding spot in the circle instead, one console line), and each clue once an officer is within `activateRange` of it, 40 m or more from every officer or closer where no officer can see it (`hardMin` in sight after `waveDelayMax`); the circle still shrinks towards the fugitive's hiding spot before he has appeared. `contactRing` (25-40 m): a parked car's returning driver and a stolen car's thief appear this far from the car, on a footpath point the game of the officer at the car picks in front of him and out of his sight first (no answer within `losTimeoutMs`: round the car, never closer than 25 m to any officer), wait to be put on the ground, then walk up to the car (off: 14 m and 30 m round the car, as before). `vehicleLift` (0.5 m, 0-1.5): a car made on a point of the mission's road itself (Traffic Enforcement's violator, a race loop's waypoint, Armored Truck Escort's truck and ambush cars) is lifted this far over the road there, so it never starts inside the road surface (0 = on the road's own height; a mission's own pursuit car points are used as written). Armored Truck Escort's truck is never made inside a car parked on the start or on an officer standing there: it waits for the start to be clear (the officers are told so on the HUD) and after `waveDelayMax` takes the first free spot further along the route. `ambushAheadOnly` (on): an Armored Truck Escort ambush car never appears on another vehicle, next to the truck (within `minDistance`) or behind it, and like every car it never appears within `minDistance` of an officer (a lead car driving ahead of the truck included): its slot slides further along the route, ahead of the truck (off = the ambush point's own slots only, also once the truck is past it, as before). `secondViolatorUpstream` (200 m, 0-400): a violator that follows another one on the same road (Traffic Enforcement's second violator) appears this far up the road from the officer furthest up it (officers within 100 m of the road count), so it drives towards your officers wherever they worked the first stop, and its blip shows once it has passed where they stood (0 = at the first violator's point, as before). Every pursuit car's point also goes through the director (never within `minDistance` of an officer: it waits or takes its next slot further back, `hardMin` after `waveDelayMax`) and the placer. `preferHidden` (on): of the points a wave may use, the ones your officers cannot see (behind a building, a container or a vehicle, as the nearest officers' own games check it: a line of sight from the officer's head and his camera to where the person would stand) are used first, so hostiles appear out of sight instead of in the open in front of you; seen points are still used when there are not enough hidden ones, and a fight with points on two sides comes from the side with more hidden points; a Manhunt clue closer than `minDistance` appears only where those games say no officer can see it, or in sight at `hardMin` (20 m) or further once it has waited `waveDelayMax` (20 s) (off: nobody is asked, and such a clue waits until the officers are `minDistance` away, or `hardMin` after `waveDelayMax`). `losTimeoutMs` (1500 ms, 100-5000): how long the server waits for that answer; a game that does not answer in time (or still owes an earlier answer) makes every point count as seen, the distance rules still apply (console: `wave 1 (spawns): 3 of 9 points out of the officers' sight, used first` / `no usable answer from <officer> within 1500 ms`). `ground` (`pedAbove` -0.3 to 1.6 m, `vehicleAbove` -0.2 to 1.5 m, `propAbove` -0.1 to 0.5 m, `snapWithin` 3 m), `collisionTimeoutMs` (6000 ms) and `interiorTimeoutMs` (5000 ms): how a point is judged against the ground under it (how far over the ground a person's, a vehicle's or an object's point may be; how far a point may be moved onto the ground; how long a game waits for the ground and for the inside of a building to load), for the spawn point check (see [5.13](#513-testing-tools)) and the placer. `place` (on): every new person, vehicle and object of a mission waits frozen where it appears until the game of an officer of that run near it has checked the ground there (by those ranges) and put it on the ground at that spot: a person standing on it, a vehicle on its wheels, an object on it; it is never moved to another spot. A point under the ground, floating, in water, in a wall or inside a building that never loaded stays frozen and is reported to the server instead, and the server moves it to another point the mission may use there (a shootout's other spawn points, still away from your officers), at most `retries` (2) times; after that, or with no other point, it is let go where it is, as before, with one console warning naming the point (`run <id>: ped <model> at x y z is underground (ground 31.40); used spawns[4] (70.00 170.00 31.00) instead`), so you can fix it in the mission file. `placeTimeoutMs` (8000 ms, 1000-60000): how long one waits for an officer's game, counted only while an officer is within `activateRange` of it (nobody near: it waits frozen) and not while an officer's game says it is checking it (the later ones of a big wave wait their turn there, at most 34 s plus `collisionTimeoutMs` and `interiorTimeoutMs`); then `onTimeout`: `'unfreeze'` (default) lets it go where it stands, as before, `'delete'` removes it and the mission treats it as killed: a hostage or an escort's truck removed this way fails that objective (one warning either way; a person or vehicle the mission only moved, Warrant Service's suspect who gives up at the door or the prisoner transport put on its parking point, is always let go where it stands). Off = everyone appears on the file's points as before, nothing is frozen. `enabled = false` turns all of it off: hostiles appear on the file's points as before (only the spawn point check, which you start yourself, still judges points by `ground`) |
| `Config.NpcDifficulty.preset` | `'easy'`, `'normal'`, `'hard'` or `'custom'`. Changes how NPCs fight, never the pay |
| `Config.NpcCombat` | How hard armed NPCs fight back: no automatic weapons, an accuracy cap, single shots, half damage, no headshot one-shots. See [2.8](#28-how-hard-npcs-fight-back) |
| `Config.Flee` | How long a suspect who runs from your officers keeps running: the server times every runner on foot (time in a car does not count), who sprints for `sprintSeconds` (10 s), jogs for `jogSeconds` (12 s), walks for `walkSeconds` (8 s) and is then worn out. Each suspect lasts up to `jitter` (25 %) longer or shorter, `Config.NpcDifficulty`'s `fleeMult` stretches it (`'hard'`: 20 % longer), a runner no officer comes within `recoverRange` (60 m) of for `recoverSeconds` (20 s) sprints again, and `armedTire = false` keeps armed suspects fresh. A tired runner visibly slows down: at most a jog, then a walk, at `jogRate` (0.95) / `walkRate` (0.85) of the normal speed, and with `windedClipset` he jogs, then walks winded. Once worn out he gives up as soon as an officer is within `giveUpRange` (30 m): `exhausted = 'surrender'` he kneels, `'handsUp'` he stands with his hands up (Cuff suspect either way), `'walk'` he walks on and never gives up on his own. `enabled = false` turns it off. `nearestRoute` (on): a runner, cook or inmate who scatters flees along the escape route that starts nearest where he appears, so nobody runs back across the site past your officers (`false`: the routes take turns) |
| `Config.Markers` | The objective on your officers' map: one blip for the objective they are on (for a fight or a search area, a circle and its centre) and one GPS line to it (`route`, in `routeColour`: 5 = yellow), off within `routeOffWithin` (40 m) of it and inside a circle. An officer still driving to the start gets only the line to the start, and one with a waypoint of his own gets no objective line. A suspect or car too far away for his game still shows where the server says (`farTargets`); objective blips show at the radar edge (`shortRange = false`), flash for `flashSeconds` (5 s) when new and show their distance in the map legend (`category = 2`); `areaAlpha` (80) is how solid the circles are, and a start at least `startCircleMin` (200 m) wide shows as a yellow circle. The mission start is a yellow map pin, "Mission start" (`kinds.start`), from accept until the officer arrives or the run ends (`startBlip`; `false` = only the waypoint shows it, as before): the waypoint set at accept is its GPS line, and while that waypoint is gone (the officer cleared it or set his own) the pin carries the line instead, so the start always keeps one; **Set GPS** on the tablet puts the waypoint back. `radioSilence` (`'area'`) is what Radio Silence hides: `'area'` keeps each objective's circle or its one blip (of several doors or devices only the officer's nearest) without a GPS line and without blips on people and cars, `'none'` hides every objective blip, `'full'` nothing; every mission follows it, and the Active Mission screen tells the officers which one applies (the drive to the start, the prisoner van and the tow truck always show). `kinds` sets each kind of blip's sprite, colour and size (yellow = go here, red = enemy, orange = fleeing, blue = friendly, green = safe point). Every objective gets one as it comes up: the mission's own blips when it draws them (Business Check: each door still to check is a numbered yellow blip, and the line goes to your nearest), else a yellow pin named after the objective at its spot, a Mission Builder mission's included; a moving one is followed from the server every `trackEvery` (2) seconds. Cars and suspects stay on the map at any distance (Stolen Vehicle Takedown, Street Race Bust, Pursuit Sim, Traffic Enforcement once the violator has passed you): their own red blips, and where the server has them once they are too far away for your game, with the line to your nearest. On Armored Truck Escort each officer's line goes to the truck while he is more than its clear radius (100 m) from it, else to the destination. Suspects, contacts and hostages too (Warrant Service, Prison Break, the raids' runners, Hostage Rescue, Parking Patrol, Suspicious Activity and the people of a traffic or stolen-car stop): a suspect orange while he runs and red once he fights or gives up, each hostage still tied blue and the green safe point once one is freed, a contact yellow until it is decided; a parked car that has not appeared yet shows at its kerb spot, and the Warrant Service front door has the line until you knock. Every fight (Gang Shootout, Hostage Rescue, the raids, the Weekly Boss) is a red circle with a skull, "Hostiles", round where the hostiles appear, with the line to its centre until you are inside; the Manhunt search circle is yellow with the line to its centre until you are inside, then to your nearest clue still to check (a numbered yellow dot), to a fugitive who runs (orange, red once he gives up), and back to the shrunk circle once every clue is checked. Point objectives too: Bomb Disposal's devices and the Drug Lab Raid's lab are numbered yellow blips (orange while set back) with the line to your nearest; a search for hidden devices, stashes or caches is a yellow circle with a yellow pin at its centre; a scene to process is a yellow map pin "Scene"; Beat Patrol and EVOC checkpoints are numbered yellow blips with their own line in `routeColour`, which an officer still driving to the start or with a waypoint of his own does not get. Blips that still show the same thing are kept between updates, so the line and the first flash are not redrawn. The detail blips show at the radar edge too (`shortRange`): each hostile's red dot, a boss a bigger one named after him (Gang Hideout Raid: "The lieutenant"). A device is named after the mission's target (Drug Lab Raid: "Shut down the lab"); one that was set back is orange, named after the recovery step ("Ventilate 1") and flashes until it is fixed (`setbackFlash`). A suspect who runs on foot from a car (Pursuit Sim, Street Race Bust, Stolen Vehicle Takedown) is orange. The prisoner transport and the tow truck are blue blips on every officer's map from the moment they appear until they drive off (`parts.prisonerVan.on` and `parts.towTruck.on`, shipped `true`; their look, name and range are their parts'; never a GPS line, in every Radio Silence mode). `extraParts` (shipped `false`), `refreshEvery`, `parts` and `rules` add the other parts of a mission ([3.13](#313-map-markers-every-part-of-a-mission)). Once an officer is at the action his HUD names what his objective blip leads to and how far it is ("Destination · 1.2 km", `hudLine`), and **Objective GPS** on the Active Mission screen puts a map waypoint on it (`objectiveGps`): the waypoint is then his one GPS line, follows a moving objective while it is still his, and goes when the objective ends; it is not offered while he drives to the start or under Radio Silence `'area'`/`'none'`. `enabled = false` turns it off |
| `Config.Route` | The GPS route to the mission start. `required` (`true`): officers must follow it; `abandonAfter` (30 s) off the route in one stretch ends their run as Abandoned with the type cooldown, after a warning at `warnAfter` (10 s). `false`: the route is still set and shown and **Recalculate route** still works, but leaving it never ends a run (no warning, no countdown, no cooldown); the start timeout stays. A run keeps the value it was accepted with, so a change in **Settings** applies to new runs; a test run follows its own **Start route** switch. Also `maxDeviation` (120 m off the line counts as off route), `maxRecalcs` (2) and `maxDrift` (1000 m). `lateArriveRange` (150 m): once the run is In progress, an officer still on his way follows the action instead of the start (GPS to the objective, no route check) and arrives this close to it; `0` = only the start counts. `followActionSeconds` (300 s): from then on he has this long to reach the action, never less time than he had, so the start timeout does not drop a partner who left late while he chases; the HUD and the tablet show the time left in the last 2 minutes; `0` = he keeps the start deadline from his accept |
| `Config.MissionCalls` | Tablet mission calls: `enabled`, how often (`spawnEvery`), how many open at once (`maxOpen`) |
| `Config.Events` | Type of the Day, the Weekly Boss (`weeklyBoss.days`, `points`, `payout`) and the twists your officers may choose when they take a mission: `twists.<key>` (`enabled`, `points` = share of P it adds, `cash` = its cash multiplier) for Armored Hostiles (+25 %, x1.25; only where armed NPCs spawn), Time Crunch (+20 %, x1.20) and Radio Silence (+25 %, x1.25). Several stack, up to `twistMaxPoints` (+70 %) and `twistMaxCash` (x1.95), paid only for a completed run. `modifierChance` (0) adds a random twist to that share of runs on top of the chosen ones |
| `Config.Builder` | Mission Builder on or off, what builders may pick, `noBuildZones`, `minLocations` (`1`: one location is enough for a custom mission; the Locations step suggests 3 or more as a tip), `minLocationsOverride` (`3`: an edited built-in mission keeps at least this many), `requireTestToPublish` (`false` = testing is optional, as shipped), `useMyPosition` (`true`: **Set start here** and **Add here** on the Locations step place a point where you stand, the tablet stays open), `autoFill` (`true`: **Fill N for me** on a spawn point row proposes the points around the start) and `autoFillRing` (`{ 15, 80 }`: how many metres beyond the keep-out they go, nearest and furthest), `teleport` (`true`: **Teleport** on each point for admins and the ranks granted in `Config.Permissions.builderTeleport`; [1.3](#13-mission-builder-permissions)), `supervisorItems` (`false` = only admins put items in a custom mission, as shipped; [1.3](#13-mission-builder-permissions)), `maxPointFromStart` (300 m, 50-2000: every point of a location within its start circle plus this, routes, patrol checkpoints, escort ambush points and flee paths exempt), and `spawnMargin` (40 m, 0-150): a custom mission's armed NPCs (a shootout and its boss, ambush and pursuit cars, warrant associates) must spawn outside the start circle plus this, e.g. 100 m from a 60 m start, so a fight never appears around your officers as they arrive (hostages and suspects keep `minSpawnFromStart`, 30 m), and `route.patrolSpacing` (300 m, 50-1000): a patrol (checkpoint route) recorded by driving is saved as checkpoints about this far apart, not judged as a road route, so a short beat publishes, and `defaultTeam` (patrol, training and investigation 2, tactical 4): the most officers a new mission starts with, by type, and `templates` (ten built-ins, e.g. `beat_patrol`, `gang_shootout`; `{}` = none): built-in missions a new mission can start from, copying their type, difficulty, team, times, bonuses, penalties and objectives but none of their locations |
| `Config.Downed.dropOffs` | Where a downed officer is taken when no EMS is on duty |
| `Config.Custody.tow.enabled` | `false` makes impounded cars fade out instead of leaving on a tow truck |
| `Config.Custody.serviceClearance` | `30.0` m: a prisoner van, tow truck or coroner van never appears or is put down closer than this to any player |
| `Config.Draw.hardClearance` | `100.0` m: a mission location this close to another live run's location is never drawn, even when every other location is taken; the draw then tries another mission of that type, or the start is refused with "no location free" (0 = off; `zoneClearance`, 200 m, still keeps runs apart while another location is free) |

**Player vs police**

| Setting | What it does |
|---|---|
| `Config.RealSuspects` | Rules for every case whose suspect is a real player (live crimes and volunteers), with surrender and talk-down. A suspect never gets points, cash or items |
| `Config.LiveCrime.enabled` | Live crimes from Crimson-Contracts as police cases (`false` as shipped) |
| `Config.Volunteers.enabled` | Players off duty who volunteer to be the suspect of a police mission (`false` as shipped) |

**Police teamwork**

| Setting | What it does |
|---|---|
| `Config.CrossDept.enabled` | Cross-Department Missions on or off |
| `Config.Units.invitePolicy` | `'anyone'` in a unit may invite, or only the `'leader'` |
| `Config.Challenge` | The department challenge: `enabled`, `scoring` (`'average'`, `'total'` or `'top10'`), weekly bounty |
| `Config.Leaderboard.weekStartsOn` | The day the week starts (`'monday'`) |
| `Config.Profile` | Bios, banned words, picture presets and picture links (see [3.4](#34-profile-pictures)) |
| `Config.OfficerOptions` | The choices each officer makes for their own tablet (My options), saved per character. `enabled = false` = no My options screen and every option keeps its default; `allow` (per option, `false` = officers cannot change it), `defaults` (what every officer starts with) and `bounds` (per number option, `{ min, max }` officers may pick). A department may set its own in `Config.Departments.<key>.officerOptions = { allow, defaults, bounds }`, which win for its officers. Also in **Settings** → Officer profile. Officers find them in the Officer UI → **My options** (after Profile & History), which also holds the tablet look, hide my name and **My keys** (the key bound to each Crimson-Police key mapping, or not set). The **Mission HUD** group (kept on this PC): `hudSide` (`'right'` or `'left'`), `hudScale` (HUD size, `bounds.hudScale` shipped `{ 0.8, 1.3 }`), `hudCompact` (only the current objective) and `reduceMotion` (no slide-in or flashing); all allowed, defaults as before (right, 1.0, off, off). The **Easier to read** group (saved with the character): `hudLook` (**Use my tablet look on the HUD**: the mission HUD, result card and notifications take the officer's appearance and accent, so the colour-blind or high-contrast look reaches them too) and `textSize` (`'normal'` or `'large'`: bigger text on the tablet and the mission HUD); both allowed, defaults as before (off, normal). The **Pop-ups** group (kept on this PC): `toastTime` (`'short'`, `'normal'` or `'long'`: how long notifications stay), `resultTime` (seconds the result card stays, `bounds.resultTime` shipped `{ 8, 60 }`) and `quietRun` (**Fewer pop-ups during a mission**: unit invites, commendations, rewards and profile news go only to the bell while on a run) and `keyHints` (**Key hints**: the unit ready check banner says "or press K" with the ready key, a new mission call adds "F6 opens Dispatch" and the contact HUD line names the contact key; a key not bound in GTA Settings, or bound to a mouse or pad button, is never named); all allowed, defaults as before (normal, 25, off) and key hints on (they only add text). The **Sounds** group (kept on this PC): `soundCalls` (the mission call tone), `soundUnit` (the unit invite and ready check tone) and `soundCues` (objective cues on a run: checkpoints, a defused target, a found item); on or off, all allowed, all on as before. The **Mission Board** group (saved with the character): `favouriteTypes` (mission type keys shown first, e.g. `{ 'tactical' }`), `hiddenTypes` (types folded under **Hidden types (n)**, never every type) and `skipAcceptConfirm` (**Accept in one click**: Accept starts the type at once and the confirm's warnings sit under the cards; the Weekly Boss still asks) and `usualTwists` (**My usual twists**: twist keys, e.g. `{ 'time_crunch' }`, from the twists enabled in `Config.Events.twists`, that start ticked on the accept step of the Mission Board and a mission call claim where that card offers them; the officer can untick them, the bonus line follows, and the server still checks the list and pays the bonuses only for a completed run; when the officer picks any they replace his department's pre-ticked twists, a twist the department does not offer is never ticked, and a twist switched off later is dropped from the saved list; **Accept in one click** still takes no twists); all allowed, defaults as before (none, none, off, none). The **Dispatch** group (saved with the character): `skipClaimConfirm` (**Claim in one click**: Claim takes a mission call at once, the warnings sit under the calls and a Twists button opens the old dialog; when several units claim within the claim window the nearest still wins), `callAlerts` (`'all'` or `'favourites'`: only calls of the officer's favourite types pop up, the rest still show on Dispatch; with no favourite picked every call pops up; muting every call stays **Mute call alerts** on Dispatch) and `dispatchKeyAfterCall` (for 20 seconds after a mission call pops up, the tablet key opens the tablet on Dispatch; nothing is claimed); all allowed, defaults as before (off, `'all'`, off). The **Opening the tablet** group: `openOn` (saved with the character: `'last'` = the screen it was closed on, `'home'`, or `'active_on_run'` = Active Mission on a run and Unit while a ready check waits for the officer, else the last screen) and `rememberFilters` (kept on this PC: Dispatch and the Leaderboard open with the filters used last); both allowed, defaults as before (`'last'`, off). The **During a mission** group: `abandonConfirm` (saved with the character; on = **Abandon** asks in a dialog as before; off = no dialog: the button turns into **Click again to abandon** for 3 seconds, so an abandon still takes two presses and still costs the type cooldown), `skipRecalcConfirm` (saved with the character; **Recalculate in one click**: Recalculate route draws the new route at once, `Config.Route.maxRecalcs` still counts) and `distanceUnits` (kept on this PC; `'metric'` = m and km as before, `'imperial'` = ft and miles on the mission HUD, the run bar, Active Mission and Dispatch); all allowed, defaults as before (dialog on, Recalculate asks, metric). The **Unit** group (saved with the character): `autoReady` (**Auto-Ready**: when the unit leader accepts a mission type, the officer is Ready at once, but only while at the keys (no pause menu, game input in the last minute) and within `autoReadyRange` metres of the leader, shipped `150.0`, 10 to 1000, server-side positions; farther away the banner asks as before; **Not ready** still works after an automatic Ready; never for a Cross-Department join). It ships locked and off (`allow.autoReady = false`): turn it on for everyone here, or for one department in **Admin** → **Departments** → Edit → Officer options. The **Map** group: `objectiveGps` (saved with the character; `'route'` = the GPS line to each objective as before, `'waypoint'` = a map waypoint set on each new objective instead, e.g. each door of a Business Check, never over the officer's own waypoint, `'off'` = neither; the **Objective GPS** button still sets one; Radio Silence still hides it and the drive to the start keeps its route), `hudTargetLine` (kept on this PC; the HUD line naming the objective and how far it is) and `colourblindMap` (kept on this PC; objective blips, circles and the line in blue, yellow, orange, white and purple, never red or green; enemies are purple); all allowed, defaults as before (`'route'`, on, off). Later updates add more groups |
| `Config.Commendations` | Commendation kinds and limits; `announce = true` posts them to the board webhook |

**Economy and rewards**

| Setting | What it does |
|---|---|
| `Config.Goals` | Daily and weekly goals and their points |
| `Config.XPLevels` | Names and colours of the XP level bands (for show only) |
| `Config.Rewards` | Item rewards, off by default (see [3.3](#33-item-rewards)) |
| `Config.Disputes.windowHours` | How long officers have to dispute a run (48 hours) |

**System**

| Setting | What it does |
|---|---|
| `Config.Limits` | `maxCompletionsHour = 8` and `maxCompletionsDay = 0` (0 = no cap) finished missions per officer; `maxConcurrentRuns = 12` and `maxConcurrentTactical = 4` missions at once, server-wide; `playerInfoCacheMs = 1000` how long a player's Qbox data (job, duty, name, callsign) is reused before Qbox is asked again (every Qbox change clears it at once; 0 = ask every time); `netRateResponse = 'block'` what a player who keeps sending one tablet request past its limit gets: `'block'` refused quietly, `'log'` also one console warning a minute, `'kick'` dropped from the server (from 3 times a request's limit, at least 20 times, in a minute; admins are never warned about or dropped); `exportBps = 200000` bytes a second for the big Admin UI downloads (Audit and Payments → Export, up to 5000 rows), sent in the background so the rest of the tablet keeps answering (below 100000 counts as 100000; 0 = in one go, as before) |
| `Config.Time.resetHour` | The hour (0–23, server time) of the daily reset |
| `Config.AntiCheat` | Flag limits, and the automatic suspension: 3 voided runs in 30 days = 7 days. `stunNeedsProof` (`'flag'`): a stun counts as before, and one the server did not see (the suspect did not fall) adds a note for staff in the Review run detail, so nobody's points are held. `'hold'` = the same, but that officer's points wait for review; `'strict'` = a fleeing person only gives up to a stun the server saw (a cheat menu cannot fake one); `'off'` = no check (the old way). A saved `true` from an earlier version reads as `'strict'`, `false` as `'off'`. `stunRecheck` (2 s): in `'flag'` and `'hold'` the note or flag waits this long and is dropped when the server saw the suspect fall by then (a real taser report often reaches the server before its copy of the suspect falls); 0 = decide at once. `adminProbeLines` (5): a player who is not an admin and sends a request only admins may send (the money, void and other Admin UI tools; no officer or supervisor screen sends one, so it is almost always a cheat menu) is refused as always, and a console line, kept in **System → Problems**, names him and the request (`player 7 (Name) sent admin-only server:admin:adjustPoints while not an admin`): once a minute per player and request, at most this many lines a minute per player (0 = no line) |
| `Config.Testing` | Admin test mode: `enabled`, `maxTesters`, `allowTeleport`, `debugOverlay`, `panelKey` (`'F7'`: the default test controls key, see [README 6.2](../README.md#62-keys)), `panelKeyGuardMs` (300 ms: the test controls key is ignored this long after the panel lets go, so the same press does not take it back; 0 = off), and `spawnCheck` (the spawn point check: `enabled`, `sceneTimeoutMs` 8000, `moveWithin` 150 m, `routes = false` checks no route points, `teleport = true` the Teleport here button next to a result) |
| `Config.Retention` | Clean-up of old data: runs archived after 12 months, audit rows deleted after 180 days, mission calls after 90 days (0 = keep) |
| `Config.Performance.loopScale` | How often the background loops wake while idle or far away (`1.0`: the shipped pace in `docs/dev/LOOPS.md`; `2` = half as often, up to `4`). Markers near you still draw every frame and run timers keep their own pace. See **Performance** below |
| `Config.Performance.pushGapMs` | The least time between two tablet updates of the same kind to one player (`0`: each sent at once, as before; up to `2000` ms). With `250`-`500`, a burst of updates (a run's progress, a unit change, the board) reaches the tablet as one, a moment later. See **Performance** below |
| `Config.Performance.latentAboveBytes` | Tablet answers bigger than this many bytes (boards, mission lists, admin lists) come in the background at `Config.Limits.exportBps`, like the Admin UI exports, so the rest of the tablet keeps answering while one loads (`0`: only the exports, as before) |
| `Config.Performance.markerRange` | Metres within which the objective markers that draw every frame (escort, suspect, scene, rescue, clue, point and device markers) draw (`0`: each marker's own distance, 30-150 m, as before; up to `150`). A smaller value (try `60`) means a far marker costs nothing until you come closer. The checkpoint course keeps its own distance |

**Performance**

Crimson-Police's loops wake as seldom as their feature allows (every loop, its interval and why are in
`docs/dev/LOOPS.md`): the objective pointer and the run's vehicle check every 2 s, mission markers far away every 1.5 s
(every frame once you are in range), the NPCs' AI every 1 s, the open tablet's walk-away, item and downed checks every
1 s (one shared loop), the server's background checks every 2 s (unit invites 5 s, the daily boundary 60 s, the happy
hour end 30 s while one runs), and the tablet's screens poll at most every 20 s (a server push still refreshes them at
once). The run engine's 1 s tick (run deadlines and HUD timers) runs only while a run, test or unit exists: with no
run the server's per-run ticks sleep, and with no run and the tablet closed the client calls no game native at all.
Every player's tablet page loads only the officer screens at start; the Admin UI, the Supervisor Mission Builder and
the criminal tablet load when first opened.

If resmon still shows Crimson-Police higher than you want, these settings help (Admin UI → Settings, section
Performance; all as shipped change nothing):

- `Config.Performance.loopScale`: `2` halves every idle and far-away wake again, `4` is the slowest. A higher value
  makes far markers, the map pointer and the walk-away close react later (at `4`, up to 6-8 s), never the per-frame
  drawing near you.
- `Config.Performance.markerRange` (try `60`): caps how far away the per-frame objective markers draw.
- `Config.Performance.pushGapMs` (try `250`): merges a burst of tablet updates into one per kind and player.
- `Config.Performance.latentAboveBytes` (try `65536`): sends big answers in the background.

`config/blocks.lua` holds the Mission Builder's ranges and defaults, and `config/banned_words.txt` the default list
of words refused in bios (one per line). Read that list and change it for your community.

### 2.6 Change any setting in game: the Settings screen

Admins can change **every** setting of `config/config.lua` and `config/blocks.lua` in game, with no file to edit and
no restart to do by hand. Type `/CrimsonPoliceAdmin` and open **Settings**.

- **It opens in Simple**: only the about 25 everyday settings (Debug, language, the tablet key, desk distance, pay
  account and daily cap, NPC distances, accuracy and damage, the runner times, the GPS line, Radio Silence, mission
  calls, the Builder minimums, the test overlay, the daily and weekly reset), under the plain groups below, each with
  a plain name and a short help text and no `Config.` path. **All settings** (the switch next to the filters, or the button under the
  list) shows every setting as below. The search and the **Changed** and **Needs a server restart** filters always
  look through every setting. In Simple, the mission tweaks and disabled locations say "Change this per mission in
  Missions" with a button, instead of a JSON box.
- **All settings lists every setting**, grouped like the file (Tablet and commands, Departments, Mission types, Cash,
  ... and the Mission Builder ranges of `blocks.lua`), with the note from `config.lua` as its description (every
  setting has one; a field inside a list takes its `field: text` line from above the list). Use the search box (a
  name, a path like `Tablet.deskDistance`, or a word of the note), or the **Changed** and **Needs a server restart**
  filters.
- **Grouped by who you play against**: Simple and All settings put the sections
  under **NPC missions** (mission types, stars, spawning, NPC combat and running away, markers, mission calls, events
  and twists, custody, the Builder), **Player vs police** (Real suspects rules, Live crimes, Volunteer suspects),
  **Police teamwork** (units, cross-department operations, Mission controls, field training, points, goals,
  leaderboard, challenge, profile), then **Tablet and dispatch**, **Pay and rewards** and **Server**. A section with
  no everyday setting shows a button to its settings in All settings.
- **The gear on every Admin UI screen** (the button at the top right, next to the breadcrumb) opens only that
  screen's settings in a side panel: Money's gear shows cash, pay editing and both kinds of rewards, Map markers'
  gear the map markers, Player suspects' gear the real suspects, live crimes, volunteers and the criminal tablet, and
  so on. The rows, checks, ENABLE prompts, saves and audit are the same as here, and a search box looks through that
  screen's settings. Every setting is under at least one gear, and **All settings** (the panel's button) still lists
  every one.
- The **Presets** tab sets a group of settings in one click. **Casual** (no route rule, NPC hints on, a case-failing
  choice asks first), **Serious RP** (the route rule on, no hints, no warning, a reason for every pay change) and
  **Go-live** (Debug lines, test teleports and the debug overlay off, a reason for every pay change). **Preview**
  lists every change with its value now and after (settings already there are only counted); **Apply** saves them,
  each one audited and in the History like a single setting, with "Preset: <name>" as the reason. Nothing changes
  until you apply, and **Reset** on a setting still puts `config.lua`'s value back. A preset never sets the admins,
  the permissions, where data is saved, a money switch (ENABLE), a setting that posts to a webhook or one only
  `config.lua` may change. Change the presets, or add your own, in `Config.AdminUi.presets` (a list of
  `{ path = 'Debug', value = false }` per preset; `{}` = no presets).
- The **Features** tab lists every feature you can turn on or off, by the same sections: each with its name, its
  `Config.` switch, On or Off, and a **Settings** link that shows that setting in All settings. The switch there saves
  the same setting as the list (audited, Reset puts `config.lua`'s value back) and works at once. Risky ones (safe
  spawning, the GPS route, mission calls, live crimes, volunteers, Mission controls, field training, item rewards)
  ask first; cash and items for live and volunteer cases and the feature rewards (3.12) are plain switches (they
  ship off; only the admin money tools still need the typed **ENABLE**).
  Mission blocks have no switch of their own: turn a mission or one of its locations off in **Missions**. Under a
  feature, **Limits** shows a button for each of its caps, cooldowns and per-day counts with its value now (for
  example Mission controls: bans, notices and points a day; field training: rookies per trainer; item rewards: the
  daily caps); a click opens that setting. Every limit, cap and cooldown in `config.lua` has an allowed range in
  Settings, so a typo (a day cap of 50000) is refused.
- **Clicking a section in the list** shows that section from its top, even when the page was scrolled far down. A
  few settings whose names would read alike have their own plain names (for example **Default tablet key** and
  **Players may open the tablet with a key**); they come from `settings.label.<path>` in `locales/parts/settings.json`.
- **Each setting has the right control**: a switch for on/off, a number box with its allowed range, a text box, a
  colour picker, a list editor, and a text box for tables (written as JSON, for example the scaling rows).
- **Save** checks the value on the server and uses it at once. The value next to it, `config.lua: ...`, is the
  file's value. A setting you changed shows a **Changed** badge, and **Reset** puts the file's value back.
  **Reset all** puts every setting back.
- **Changes are kept.** They are saved in your database (or the saves folder with the database off) and survive
  restarts and updates. A change made in game wins over `config.lua`. You can still edit `config.lua`: a setting you
  never changed in game keeps following the file.
- **A few settings are read only when Crimson-Police starts** (default keys, mission desks, the language, the hour
  of the daily reset and the first day of the week). They have an **Needs a server restart** badge: the
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

### 2.7 Turn missions and locations on or off

Admin UI → **Missions** has a switch next to every mission, built-in and custom:

- **Off**: the mission is never drawn again (Mission Board, mission calls, Cross-Department Missions, the Weekly Boss).
  A run of it that is already going finishes normally.
- **Locations**: the **n/m locations** button lists every location of the mission with its own switch. A location
  turned off is never drawn. With every location off, the mission is never drawn.
- **Reset to default** in that window puts the mission's switches back to `config.lua`'s.
- The switches work at once, are saved like every other setting (database or saves folder), and are in the audit log.
  They are `Config.DisabledMissions` and `Config.DisabledLocations` in `config.lua`.
- A built-in location that was renamed keeps its old label in the mission file (`aliases`), so a switch saved by the
  old label still turns it off; Admin UI → **Missions** shows the new label.
- Nothing needs a test before it is used: a mission you just switched on is drawn at once.

### 2.8 How hard NPCs fight back

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
| `reassertAiDamage` | `true` | Both values above go on again every 2 s of a run, so another script that changes them (Crimson-Contracts' guards reset them when its guards are gone) cannot leave your officers' NPCs at full damage. `false` = they are set at the start of the run and after a respawn only (the old way). Its earlier name `holdAiDamage = false` still counts while this key is missing |
| `officerDefense` | 1.0 (off) | The damage officers on a run take from every weapon, players' shots too (0.5 = half). Leave it at 1.0 unless `aiDamage` alone is not enough |
| `noCriticalHits` | `true` | Officers on a run take no extra headshot damage, from anyone: a headshot hurts like a body shot |
| `cancelLethalHeadshots` | `true` | The server drops a hit from a mission NPC that would kill a healthy officer of its run in one shot (a headshot, a point-blank shotgun blast) |
| `lethalCancelAbove` | 0.75 | How healthy "healthy" is: the officer still has at least this share of his health (0.25 to 1, 0.75 = three quarters). The shot that finishes off an officer who is already hurt always counts, so officers can still go down |
| `playerHitDropsProtection` | `false` | `true` = once a real player who is not on the run shoots an officer on an NPC mission, that officer loses `noCriticalHits` and `officerDefense` for the rest of that run (headshots and damage as GTA has them; NPC bullets stay softer). `false` = he keeps them whoever shoots him, as before |

Good to know:

- Each officer's own game applies `aiDamage`, `aiMeleeDamage` and `noCriticalHits` while that officer is on a run, and
  again after a respawn (`aiDamage` and `aiMeleeDamage` every 2 s, with `reassertAiDamage`). `aiDamage` softens every
  NPC bullet his game works out during the run, so an NPC of another script next to him, or a mission NPC shooting a
  hostage, hits softer too.
- `cancelLethalHeadshots` can only catch the hits the server hears about (an NPC that another officer's game moves).
  `noCriticalHits` covers the rest. Neither ever touches a player in Crimson-Arena. It never makes an officer
  unkillable: once he is below `lethalCancelAbove`, the killing shot goes through and he goes down as usual.
- The built-in missions now name pistols and pump shotguns only, and the Mission Builder and Quick edit never offer
  an automatic weapon. A custom mission from an older version that still names one keeps working: one console line
  names it ([8.3](#83-missions-and-the-mission-builder)), and its NPCs carry the `replace` weapon.
- With `enabled = false` nothing is swapped, so the Mission Builder's list (`Config.Builder.allowed.weapons`) is the
  only check again: a custom mission that names a weapon outside it is not loaded (one console line says why) until
  you put the weapon back in that list. Switching `enabled` in Settings reloads the missions at once.
- To feel the difference, run Gang Shootout alone in Admin UI → **Testing**, then change `aiDamage` or
  `accuracyMax` in Settings and run it again.

---

### 2.9 Baked in: one way to do each thing

Some switches only chose between an old and a new layout of the same screens. The better layout is now the only one
and the switch is gone; nothing was taken away, and every action, permission, grant, department scope, audit row and
money switch is where it was. A value saved in game for one of these keys is skipped quietly at start; delete the key
from an older `config.lua` (Crimson-Police ignores it).

| Removed key | Now always | Where it is |
|---|---|---|
| `Config.AdminUi.groupSidebar` | everyday screens on top, the rare tools under **More** | Admin UI sidebar ([5.3](#53-the-admin-panel)) |
| `Config.AdminUi.groupByPlay` | screens and settings grouped by NPC missions, Player vs police, Police teamwork, then the rest | Admin UI sidebar, Settings ([2.6](#26-change-any-setting-in-game-the-settings-screen)) |
| `Config.AdminUi.plainLayout` | plain names, six described groups, the screen search and the breadcrumb | Admin UI sidebar ([5.3](#53-the-admin-panel)) |
| `Config.AdminUi.landing` | the Admin UI opens on **Home**, whose tiles open Money and Missions | Admin UI → Home |
| `Config.AdminUi.settingsView` | Settings opens in Simple; **All settings** is one click away | Admin UI → Settings |
| `Config.AdminUi.homeForms` | the Home shortcuts hold their quick forms; **Open** opens the full screen | Admin UI → Home |
| `Config.AdminUi.markersScreen` | the **Map markers** screen is shown | Admin UI → NPC missions → Map markers ([3.13](#313-map-markers-every-part-of-a-mission)) |
| `Config.AdminUi.needsAttention` | Home's **Live now** queues and **Alerts** (UI3: one dashboard) | Admin UI → Home |
| `Config.AdminUi.oneRequest` | Payments made and Leaderboards open with one request each | Admin UI → Money → Payments, Leaderboards |
| `Config.AdminUi.windowRows` | long lists draw only the rows in view | every tablet UI |
| `Config.AdminUi.foldAdvanced` | settings-heavy dialogs and Mission controls fold the rare options under **More** | Admin UI dialogs, Supervisor UI → Department → Controls |
| `Config.Builder.foldAdvanced` | a block's basics open, the rest under **More settings** | Mission Builder → Details and block settings |
| `Config.Builder.quickWizard` | **New mission** opens the 4-step wizard; the New mission dialog is its **Open the full editor** | Mission Builder ([5.12](#512-mission-builder)) |
| `Config.Tablet.supervisorByTask` | the Supervisor UI sidebar under People, Missions and Rewards | Supervisor UI sidebar ([1.1](#11-the-supervisor-ui-layout)) |
| `Config.Tablet.supervisorRemember` | Give points, Mission ban and Clear cooldown open with the values last used | Supervisor UI → Department → Officers |
| `Config.Tablet.supervisorReviewLive` | a decided flagged run or dispute leaves every other open Review Queue at once | Supervisor UI → Department → Review |

**Kept as settings**, because a city may want them differently: `Config.AdminUi.reasonChips` (your own reason
buttons), `Config.AdminUi.homeShortcuts` (Home's shortcuts and their order), `Config.AdminUi.presets` (the Settings presets), `Config.Tablet.sidebarOrder`, `activeFirst`, `compactSidebar`, `supervisorCompact` and `supervisorLanding`
(how each city likes its sidebars), and the tuning numbers `Config.AdminUi.pageSize` and `Config.Performance.loopScale`,
`pushGapMs`, `latentAboveBytes` and `markerRange` (each shipped as before).

The old screen keys of merged screens (`admin_payouts`, `admin_rewards`, `admin_payments`, `admin_blips`,
`sup_report`, `sup_controls`, `sup_review`) and the old Map markers names (`Config.MissionBlips`,
`Config.Markers.serviceVehicles`, `Config.AdminUi.missionBlipsScreen`) are no longer read: use **Money**, **Map
markers**, **Department** and `Config.Markers` (its `extraParts`, `refreshEvery`, `parts` and `rules`).

## 3. Optional extras

Each extra is off, or works with no change, until you turn it on.

### 3.1 The tablet item

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
   item in the inventory, and the tablet closes when the item leaves the inventory. Accepting a mission and
   claiming a mission call check the item again (not needed while the officer is still at the desk the tablet was
   opened at).
5. Restart the server (or restart ox_inventory, then Crimson-Police). The start-up check says whether the item and
   its picture were found.

Give the item to officers any way you like, for example in an sc-police armoury or a shop.

### 3.2 Mission desks

A mission desk is a spot at a police station where officers open the tablet with ox_target ("Open Crimson-Police"),
standing at a computer instead of holding a tablet. Walking more than 3 metres away closes it. A desk works even
with `requireItem = true`.

Three desks ship **on**, in `Config.Tablet.desks`, one per police station the Qbox police script (qbx_policejob)
knows. Mission Row PD and Paleto Bay sit 1.5-3 m from that script's duty points, facing them, in the normal game
interiors; Sandy Shores keeps its earlier spot (Qbox has only a map blip there). Each `coords` line names its source:

```lua
-- inside Config.Tablet (shortened)
desks = {
    {
        label = 'Mission Row PD front desk',
        coords = vec3(441.00, -977.30, 30.69),     -- from qbx_policejob config/shared.lua:21 (the duty point)
        size = vec3(1.2, 0.8, 1.0),
        rotation = 21.0,
        departments = nil,       -- nil = every department; or e.g. { 'sast' }
        prop = false,            -- or a laptop model like 'prop_laptop_01a' that only that player sees
    },
    -- then 'Sandy Shores office' and 'Paleto Bay sheriff front desk'
},
```

- A station with a custom interior (MLO) may need its desk moved: Admin UI → Departments → **Desks** (move, add and
  remove desks in game), or edit `coords`.
- To turn all desks off, set `desk = false` in `Config.Tablet.access`.
- Admin UI → **Departments** lists every desk. The start-up check warns about a desk with bad coordinates.

### 3.3 Item rewards

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
  deliver, cancel or take back a reward: see [5.15.4](#5154-payments-item-rewards-and-department-money). A pool
  changed in game is checked at once: a forbidden or unknown item is never given.

### 3.4 Profile pictures

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
- Supervisors approve pictures in Supervisor UI → **Department** → **Review** → **Profiles**, admins in Admin UI →
  **Officers**.
- `Config.Profile.bioRequiresApproval = true` also makes new bios wait for approval.

### 3.5 Database off: the saves folder

With `Config.Database.enabled = false` (as shipped, see [README
5.1](../README.md#51-the-two-switches-at-the-top-debug-and-storage)), Crimson-Police keeps all its data as files in
`Crimson-Police/saves/`, and nothing in your database. Every feature works the same: runs, points, XP, payouts,
boards, seasons, disputes, suspensions, the audit log and custom missions.

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
- `saveTurnMs` (4 ms): every change is written to the folder before Crimson-Police goes on, and after 4 ms of writing
  it lets the server run its other work for a moment before the next write, as oxmysql does with the database. So when
  several officers finish a mission together, the server does not stall while their results are saved. The data
  saved is the same. 0 = write everything in one go, as before.
- `jsonCacheEntries` (100000): files mode keeps the answers of the JSON lookups it reads again and again (every
  badge check reads an officer's whole history), so a server with a long history checks badges in a few
  milliseconds. About 50 bytes each, so 100000 is about 5 MB. The answers are the same with any value; 20000 was the
  old size, 0 keeps none.
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

### 3.6 Discord webhooks

Five optional webhooks, set as convars in `server.cfg` (the block in [README
3.2](../README.md#32-paste-this-into-servercfg)). Leave out any you don't want.

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

### 3.7 Department logos

- One file per department in `Crimson-Police/logos/`, named as in `logo.file` of that department (`sast.png` for
  SAST). PNG, WebP or SVG. A square, see-through PNG of at least 1024 × 1024 pixels looks best.
- `sast.png` and `fib.png` are placeholders. Replace them with your own art and restart Crimson-Police. Nothing
  needs to be rebuilt.
- Instead of a file you can use a direct image link: `logo = { url = 'https://…/logo.png', ... }`.
- The other logo settings: `watermark = true` draws the logo behind every screen, `opacity` (0.0 to 0.25) sets how
  faint it is, `size` is its share of the tablet height, `grayscale = true` removes its colour.
- A missing file gives one console line, and that tablet shows no logo until you add the file and restart.

### 3.8 Paying from the department's bank account

By default payouts are new money (`Config.Cash.source = 'server'`). To take them from the department's
Renewed-Banking account instead:

1. Set `source = 'society'` in `Config.Cash`.
2. Check each department's `societyAccount` (`'sast'`, `'fib'`) is the name of its Renewed-Banking account.
3. Put money in those accounts. An account without enough money can't pay: that officer gets no cash for the run,
   and the officer, the department's online supervisors and the console are told ("unfunded").
4. In your Qbox jobs file, give `bankAuth = true` to the grades that may see and fund the account in Renewed-Banking.

Admin UI → **Departments** shows each account's balance and spending (the **Funds** part of each department; Admin
UI → **Money** → **Department funds** shows the same cards for every department on one page), and Admin UI → **Money**
→ **Payments** shows every unfunded payment with a **Retry unfunded** button (a switch that ships off). An
account Renewed-Banking does not know shows as an error in the Config health list, and `Config.Cash.lowBalanceWarn`
warns before an account runs dry. See [5.15.4](#5154-payments-item-rewards-and-department-money).

### 3.9 Handcuff and evidence items

Off by default. In `Config.Custody`:

- `handcuffsItem = 'handcuffs'` makes Detain and Cuff suspect need that ox_inventory item (it is checked, not used up).
- `evidenceItem = 'evidence_bag'` gives each officer one per mission, taken back when the mission ends.

Use item names that exist in your ox_inventory.

### 3.10 Adding a department

**In game (no restart):** Admin UI → **Departments** → **Add department**. Give it a key (it can't change later), a
name, a short tag, its Qbox job, the supervisor grade, its society account and colours copied from another
department; upload its logo on the same screen. Its officers can open the tablet at once. A department added in game
can be turned off again, and deleted while it has no history ([5.15.5](#5155-system-departments-and-settings)).
Then do step 4 below for sc-dispatch and sc-police.

**In config.lua** (the old way, still works):

1. In `Config.Departments`, copy the `fib` block (or remove the `--` from the `bcso` example at the end of the
   list), and give it its own key, like `bcso`.
2. Set `label`, `short`, `jobs`, `supervisorGrade`, `societyAccount`, `theme` and `logo`.
3. Put its logo (for example `bcso.png`) in `Crimson-Police/logos/`.
4. Check the job is in sc-dispatch's `Config.Police.AllowedJobs` and sc-police's
   `Config.DispatchIntegration.PoliceJobs` (`bcso` already is in both).
5. Restart Crimson-Police. No code and no SQL changes. A department added in the middle of a season starts at 0.

### 3.11 Field training (FTO)

Off by default (`Config.FieldTraining.enabled = false`): nothing changes until you switch it on (in config.lua or
Admin UI → Settings → Police → Field training).

1. Set who may train: `Config.FieldTraining.trainerGrades`, the lowest Qbox grade of a trainer per department
   (`{ sast = 2, fib = 2 }` shipped; a department you leave out uses its `supervisorGrade`).
2. Set the sign-off tasks: `Config.FieldTraining.tasks`, how many completed missions of each type the rookie must run
   with his trainer (`{ patrol = 3, investigation = 2, tactical = 1 }` shipped). In Settings both lists are edited as
   a whole: you may leave a type (or department) out or add one, for example `{ "tactical": 1 }` for one Tactical
   run only; a key that is not a mission type (or department) is refused.
3. `rookiesPerTrainer` (2) caps the rookies one trainer has at once; `badge` (`field_training`) is the badge a rookie
   gets at the end. While field training is on, an admin can also grant or revoke it in **Admin UI → Officers →
   Badges** like the other badges.
4. Optional ride-along rule: `requireTrainerFor`, a list of mission type keys (for example `{ 'tactical' }`) a rookie
   may only accept (or claim as a mission call) with his trainer in the same unit. The same rule holds when he joins
   a live case as backup: only while his trainer is on that case. Shipped empty: a rookie takes every type with
   anyone.
5. Optional trainer bonus: `trainerBonus`, points the trainer gets for each task he signs off (shipped 0 = none; at
   most 1000). The points show in his history as "Field training sign-off".

How it plays: a supervisor opens **Supervisor UI → Department → Training → Pair trainer**, picks a rookie of his
department and an online trainer, and confirms (an admin can do it for any department). Missions the rookie completes
in a unit with his trainer, both finishing the same run, count towards the task of that mission type. When a task's
count is reached the trainer gets a toast and signs it off in **Profile → Field training**, with an optional note; the
rookie sees his progress, his trainer, the sign-off notes and the mission types he may only take with his trainer on
the same card, and the trainer sees his trainees there with a **Sign off** button. When every task is signed off the
rookie gets the **Field Training** badge. **End training** (click twice) removes a pairing. Pairing, ending and every
sign-off are in the audit log. Nothing is lost on a restart: the training is saved with the officer (database or saves
folder).

### 3.12 Feature rewards: money and items for every feature

Missions pay their type's payout (2.3). `Config.FeatureRewards` pays the features outside a mission, each with a
money amount already set, and **every one ships off**: nothing pays until you switch it on in **Admin UI → Settings →
Features → Money** (no typed word needed). Each row there shows its money, account and items as buttons, and the
**Item rewards** switch they share, so you can see at a glance whether items are on.

| Feature | Who is paid | Default money |
| --- | --- | --- |
| `suspect` | the volunteer who played a suspect (see the rules below) | escaped $1500, caught $500 (`money.got_away`, `money.caught`); `byType` sets other amounts per mission type |
| `surrender` | the officer who talked a live-case suspect down (once per suspect, paid when the case ends played out: not abandoned, cancelled or flagged) | $300 |
| `ftoSignOff` | the trainer, for each task he signs off (once per rookie and task) | $250 |
| `ftoComplete` | the rookie, when his training is done (once) | $1000 |
| `supAward` | the officer a supervisor gave points (Give points) | $5 a point, at most $2500 (`maxMoney`) |

- `suspect.byType` (shipped `{}`): dollars by mission type, e.g. `byType = { investigation = { got_away = 2000,
  caught = 600 } }`. A mission type or an outcome you leave out pays `money.got_away` / `money.caught`; the criminal
  tablet's Jobs card shows the amounts of the job's own type. Settings refuses a type that is not in
  `Config.MissionTypes`.
- **The Rewards tab**: Admin UI → **Money** → **Rewards** puts every feature that pays on one page:
  each NPC mission type (its payout, paid as `Config.Cash.account`, and its own `Config.Rewards.byType` item pool),
  live cases and volunteer cases for officers (their cash and item switches; they pay the mission type's payout),
  volunteer suspects (money by outcome and by mission type), talk-downs, field training and supervisor awards (each
  with its switch, money, account, money item and items list). The items use the same item picker as Settings (only
  items your ox_inventory has; the server checks every name again). The **Item rewards** switch sits on top with a
  one-click **Turn item rewards on**. Every change saves like a setting (checked, audited, in Settings → History).
  The tab only shows and edits the settings: nothing is paid differently because of it.
- `account`: `'bank'`, `'cash'` or `'item'`. With `'item'` the money is paid as the item in `moneyItem` (shipped
  `'black_money'`, a dirty-money item; it must exist in your ox_inventory), one item per dollar.
- `items`: add items per feature, e.g. `items = { { item = 'water', count = { 1, 2 }, chance = 0.5, value = 20 } }`
  (count a number or a low and a high, chance 0-1 per payment, value for `Config.Rewards.dailyValueCap`). Settings
  refuses an item ox_inventory does not know and the forbidden ones (weapons, ammo, money items...). Items are given
  only while `Config.Rewards.enabled` is on, under its daily caps.
- Every payment is a row in **Admin UI → Payments** (named, for example, "Suspect pay (volunteer case)"), audited as
  "Feature reward paid", paid once per case whatever happens twice, pending until the player logs in if he is
  offline, and counted in `Config.Cash.dailyCap`. With `Config.Cash.source = 'society'` officers are paid from their
  department's account; a suspect is always paid new money.
- A volunteer suspect is paid only for a case the server saw end fairly: officers reached him, he did not drop out
  (no-show, cancel, logging off, leaving the search circle), he was not AFK, and his outcome was escaped, detained or
  booked. Test runs never pay.

### 3.13 Map markers: every part of a mission

Map markers (`Config.Markers`) is the one blip system of Crimson-Police: it marks the objective, the prisoner van
and tow truck coming to you, and, if you want, every other part of a mission on the minimap and the big map. The
other parts ship off: with `Config.Markers.extraParts = false` only the objective, the prisoner van and the tow
truck show, as before.

The easy way is Admin UI → **Map markers** (under NPC missions). On top are the objective's own settings (its blip, GPS line, Radio Silence, HUD line) and
the look of each kind of objective blip. Then the switch of the extra parts (**Turn on**) and how often the server
checks. Below it is one row per part, each with:

- its **on** switch (the prisoner van and tow truck have their own switch, shipped on; every other part that is on
  waits for the extra parts' switch, and says so);
- its **look**: the picture (pick a named one such as Van, Car or Hospital, or type any blip id), the colour (pick
  a named one such as Blue or Red, or type any colour id), the size, the name on the map and **Only when near**;
- **Who sees it**: tick departments, jobs and mission types, add missions, set the lowest grade and pick everyone,
  the unit leader or supervisors. Nothing ticked means any. **Remove the rules** shows the part to everyone again.

You can also find it in Admin UI → **Settings** → **Features** (one Map markers row, which links the extra parts'
switch) and edit every value in Admin UI → **Settings** → Missions and Builder → **Map markers** (or in
`config/config.lua`). Changes work at once, no restart, and every change is saved and audited like any setting.

| Part | What it marks |
|---|---|
| `prisonerVan`, `prisonerDrop` | the prisoner van (its own switch, shipped on), and where it waits for the hand-over |
| `towTruck`, `impoundDrop` | the tow truck (its own switch, shipped on), and where it waits to load the car |
| `coronerVan`, `coronerDrop` | the coroner van, and where it waits for the body bags |
| `evidence` | clue props and body bags |
| `suspectVehicle`, `parkedCar` | a suspect's or stopped car, and the parked cars of a scene |
| `witness`, `hostage`, `device` | witnesses and people to talk to, hostages, devices to work |
| `hidingSpot` | where a Manhunt fugitive hid, once he was found |
| `sceneProp` | other props of a scene |
| `ambush` | ambush cars and attackers, once they appear |
| `hospitalDrop` | the nearest hospital while a live-case suspect is down |
| `partner` | the other officers of your run (police blue) |
| `reportedPoint` | a live case's reported scene and last-reported points |

Each part has `on`, `sprite`, `colour`, `scale`, `label` (`''` = the built-in name) and `shortRange` (`true` = only
on the minimap when near). The prisoner van and tow truck are drawn once each (never a second blip), in every Radio
Silence mode, while their `on` is `true`.

**Who sees a part**: `Config.Markers.rules` limits a part by department, job, lowest grade, mission type,
mission and role. All rules you set must match; a part without rules shows to everyone on the run:

```lua
rules = {
    partner = { departments = { 'sast' }, roles = 'leader' },        -- only SAST unit leaders see their partners
    evidence = { missionTypes = { 'investigation' }, grade = 2 },    -- grade 2 and up, investigation missions only
},
```

The server decides what each officer gets and sends only that. A real player suspect's live position is never shown
(a live case keeps its last-reported points only), nothing hidden shows before it is found (a staged ambush, a
hidden contact, a fugitive's hiding spot), and Radio Silence still hides people and cars ('area') or everything but
the vans ('none'), as `Config.Markers.radioSilence` says. The prisoner van and tow truck follow their rules too (an
officer the rules leave out never gets their blip). The blips go at the run's end, when you leave the run, log out,
or the switch is turned off.

---

## 4. Settings to check in your other resources

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
- **Prison and Fort Zancudo**: the Mission Builder can't place anything inside `Config.Builder.noBuildZones`. The
  215-metre `Bolingbroke Penitentiary` zone covers the whole prison, yards and every watchtower; if your prison MLO
  is bigger, widen or move it. Four `Fort Zancudo` circles cover the military base; no built-in mission uses it
  (Drug Lab Raid's old Zancudo River cabin is now the Davis Quartz site office).
- **Server time zone**: daily and weekly resets and the Weekly Boss days use the server machine's clock. Set the
  machine's time zone to your community's.

### 4.1 Locations and other scripts

The built-in missions were checked against the fixed places of the public Qbox and overextended scripts: qbx_garages,
qbx_policejob, qbx_ambulancejob, qbx_vehicleshop, qbx_management, qbx_cityhall, qbx_properties, qbx_scrapyard,
qbx_towjob, qbx_truckerjob, qbx_taxijob, qbx_busjob, qbx_garbagejob, qbx_bankrobbery, qbx_storerobbery, qbx_jewelery,
qbx_houserobbery, qbx_drugs, qbx_spawn, qbx_prison, ox_inventory (shops, stashes) and ox_doorlock, which keeps its
doors in its database and so adds none (790 places: garage markers and car spawns, shop counters, registers and safes,
bank vault doors and lockers, hospital beds, job pick-up spots, house entrances, spawn points).

- No mission start, person, car or object of a built-in mission sits on one of those places: 6 m clear of a
  garage, a vehicle spawn or a job's pick-up spot (qbx_garages keeps 5 m clear before it spawns a car), 4 m of a
  hospital, station or prison point, 2 m of anything you use with ox_target (a counter, register, safe, locker,
  stash or door), or the script's own radius when it is larger. A delivery area bigger than 10 m (the trucker's
  40 m boxes) and a wall camera are only listed.
- Bomb Disposal's counter and back-room spots, Hostage Rescue's back-office robbers, the Wild Oats Drive
  warrant suspect and the Route 68 stolen car were moved a metre or two for this; `docs/IN_GAME_CHECKLIST.md`
  lists each one to look at.
- Markers where nothing spawns stay where they are: the Beat Patrol checkpoint at the Motor Hotel car park sits on
  the qbx_garages marker, the Wild Oats Drive warrant door is the qbx_houserobbery entrance of that house, and the
  Business Check doors are the shop doors.

When you add one of these scripts or another public script, check again:

```sh
git clone <the script> <folder>/<name>               # one folder holding every script to check
# add its name and kind to SCRIPTS in tools/gen_foreign_sites.py
python3 tools/gen_foreign_sites.py <folder>          # writes tests/fixtures/foreign_sites.lua
python3 tools/restyle.py tests/fixtures/foreign_sites.lua
lua5.4 tests/run.lua foreign_sites                   # fails on a mission point inside a place
CP_FOREIGN_REPORT=1 lua5.4 tests/run.lua foreign_sites   # also lists every mission point within 50 m of a place
```

---

## 5. How it plays

### 5.1 The officer's tablet

The tablet uses the officer's department colours and logo. Every screen of every tablet (officer, supervisor,
admin and criminal) shows its name with one short line of help under it. Eight screens on the left:

| Screen | What is on it |
|---|---|
| **Home** | The officer's card (picture, callsign, rank, level, streak, season points, cash this week), today's and this week's goals, Type of the Day, open mission calls, new commendations, and the Rewards locker when item rewards are on |
| **Mission Board** | One card per mission type with its pay and points, locks (cooldown, "Server busy", "On a call", daily limit), the Weekly Boss card from Friday to Sunday, and the Cross-Department card when one is running. Officers can put favourite types first, fold types they never play and accept in one click (My options → Mission Board). **Accept** asks to confirm and lets the leader add twists (Armored Hostiles, Time Crunch, Radio Silence) for extra points and cash, with the total bonus shown ("+45% points, x1.50 cash"); a mission call claim offers the same |
| **Dispatch** | Tablet mission calls to claim, the last 5 calls, and a read-only count of real sc-dispatch calls. Officers can claim in one click, get pop-ups for their favourite types only and have the tablet key open Dispatch just after a call (My options → Dispatch). Hidden when `Config.MissionCalls.enabled = false` |
| **Unit** | Invite officers (nearest first), accept or decline, leave; the leader can kick, make leader or disband. A ready check runs before every mission (**Auto-Ready** in My options answers it for an officer near the leader, when the owner allows it) |
| **Active Mission** | The drawn mission, objectives, timer, partners, expected pay, the route to the start, and the Contact panel for police actions. Officers can abandon without the dialog (two presses), recalculate the route in one click and read distances in miles (My options → During a mission) |
| **Leaderboard** | Weekly, Monthly, Season and All-time boards, ranked by points, missions, arrests, impounds, citations, rescues, mission calls or judgement |
| **Department Challenge** | Each department's score, weeks left, this week's bounty and the top 5 |
| **Profile & History** | Picture, bio, level, service record, badges, commendations, the last 20 runs, disputes, and the tablet's look |

Also: badges on the sidebar, a notification bell with the last 20 messages, the mission HUD on screen, and a
result card after each mission.

**The Officer UI sidebar** is set in `Config.Tablet` (also in Admin UI -> Settings). Shipped: the `'classic'` order,
nothing moved, the full sidebar:

| Setting | What it does |
|---|---|
| `sidebarOrder` | `'classic'` (shipped: Home, Mission Board, Dispatch, Unit, Active Mission, Me, My options) or `'mostUsed'`: Home, Mission Board, Active Mission, Dispatch, Unit, Me, My options. Only the order changes |
| `activeFirst` | `true` (shipped `false`) = while the officer is on a run, Active Mission sits right under Home (off a run it keeps its place) |
| `compactSidebar` | `true` (shipped `false`) = a narrow strip of icons, each name on hover, so the screens get more room (handy with large text) |

The same screens show in every order; one an owner switched off (Dispatch, My options) stays hidden.

**Fewer screens for officers.** Home opens on the officer's status (on a run, today's missions done, or ready), the
goal to work on next and one big **Find a mission** button (on a run it reads **Back to your mission**); the officer
card, both goals, the Type of the Day and the news follow below. **Me** holds Profile & History, Leaderboard and
Department Challenge as three tabs (the commendations badge sits on Me); a leaderboard row or a challenge contributor
opens that officer on the Profile tab, and Back returns to the Leaderboard tab. While on a run, the bar over every
screen opens Active Mission and has quick links to Mission Board, Dispatch and Unit (Dispatch only while mission
calls are on). Display only: every action, rule and permission is the same.

Home, Mission Board, Active Mission and Dispatch share one header: the screen name, then one line saying what the
screen is for (Home also greets the officer). While a screen loads it shows a spinner; if the first load fails, the
error with Retry; if the server sends nothing, "Nothing to show yet" with Retry; if a later refresh fails, a small
"Could not refresh" line with Retry over what was loaded last. Display only: nothing an officer can do changes.
Unit, the three tabs of Me and My options use the same header and load states. Profile's field training card shows
how many of your rookies' tasks are ready to sign off, and the live case card on Active Mission says which of its
three steps the case is on ("Step 2 of 3").

**How a mission goes.** The officer (or unit leader) picks a type. The server draws a random mission of that type
(no list, no reroll). Everyone gets a GPS route to the start and must follow it: 30 seconds off the route ends
their run as Abandoned (with `Config.Route.required = false` the route is only a guide and leaving it ends
nothing). At the start the mission begins; they finish the objectives before the timer runs out. A partner who is
still driving when it begins follows the action: his GPS leads to the objective and he joins within 150 m of it
(`Config.Route.lateArriveRange`), with 5 minutes from then on to get there (`Config.Route.followActionSeconds`).
Finished = Completed (points and cash). A downed officer, or a timer that runs out, = Failed. Leaving, going off
duty or not reaching the start in time = Abandoned. Going down, leaving, going off duty or not reaching the start
also puts a 5-minute cooldown on that whole mission type (`Config.Limits.abandonCooldown`). Ending for a real
call, or a supervisor's force recall, never does. An admin can clear an officer's cooldowns, allow a few more
missions today or give another Weekly Boss attempt ([5.15.3](#5153-live-runs-units-and-anti-farm)).

### 5.2 The supervisor's screens

Supervisors play missions like officers. The **Supervisor** button in the tablet opens their own screens:

| Screen | What it is for |
|---|---|
| **Mission List** | Every mission by name. Launch a Cross-Department Mission from here |
| **Cross-Department Mission** | The running operation: start now, relaunch after a fail, cancel, remove a joiner |
| **Live Missions** | Runs of their department: force recall. Admins have their own **Live** screen for every department, with more controls ([5.15.3](#5153-live-runs-units-and-anti-farm)) |
| **Department** | One screen with five tabs. **Officers**: activity per officer this week, and **Commend**; **Give points**, **Clear cooldown** and **Mission ban** when switched on ([1.2](#12-what-supervisors-may-do)). **Controls**: the rules an admin opened to supervisors, grouped (Delays and repeats first): the config.lua value, the value in use, the admin's limits and today's use, a slider (one per mission type for the cooldowns) or a switch, **Save** and **Back to config** (both ask for a reason; the admin's ready-made reasons show as buttons), who changed it and when, and the time until the next change; shown while the supervisor may change at least one control (out of the box the cooldown controls, for every department). **Review**: flagged runs and disputes of their department, and a **Profiles** tab for pictures, bios and reports. **Calls & notices**: the Mission calls panel (withdraw, page and create calls) and the department notices. **Training**: field training, pair trainers and rookies, progress per task ([3.11](#311-field-training-fto)) |
| **Payouts** | Mission type payouts, within the allowed range |
| **Mission Builder** | Build, test and publish their own missions ([5.12](#512-mission-builder)) |

Which of these they can use is set in `Config.Permissions.supervisor` ([1.2](#12-what-supervisors-may-do)).

### 5.3 The admin panel

`/CrimsonPoliceAdmin` opens a full-screen panel for every department:

| Screen | What it is for |
|---|---|
| **Home** | Where the panel opens: a dashboard of **Live now** (officers on duty, runs going, the queues waiting), **Alerts** (problems, refused starts, Config health, the last mission load) and your **Shortcuts** (`Config.AdminUi.homeShortcuts`) |
| **Money** | Every money tool in one screen, as four tabs. **Pay rates** (the old Payouts screen): every type and mission payout, set or clear them. **Rewards**: every feature that pays, its money, account and items. **Payments**: every payment Crimson-Police made or still owes, with totals and the payment tools ([5.15.4](#5154-payments-item-rewards-and-department-money)). **Department funds**: each department's society account (the same Funds card as on Departments) |
| **Missions** | Built-in and custom missions: Builder, publish, archive, restore, roll back, break edit locks, reload files, Cross-Department Missions and mission calls |
| **Seasons & Challenge** | Start or end a season, override this week's bounty |
| **Leaderboards** | Every board, cash paid, payments stuck in "paying", void runs, award points, and the **Item rewards** tab (the flagged runs are on **Review**) |
| **Officers** | Search officers: history, suspend or unsuspend, disputes about failed runs, commendations, service record |
| **Review** | Everything waiting for a decision, as four tabs. **Flagged runs**: approve or void each one (or every flagged row of a run at once), your own runs left out. **Profiles**: pictures, bios and reports waiting, and the banned words. **Disputes**: every open dispute (a row opens the officer). **Corrections**: bulk voids, retirements, record moves and season reopens, with **Undo** |
| **Departments** | Each department's jobs, colours, logo, desks, member count and (with society payouts) account balance |
| **Missions** (switches) | Turn any mission, or single locations of it, on or off ([2.7](#27-turn-missions-and-locations-on-or-off)) |
| **Permissions** | What supervisors may do (a switch for each), **Extra grants** (a power for departments from a grade, Qbox gangs from a grade or single citizen IDs; [1.3](#13-mission-builder-permissions)), **Mission controls** (each control's switch, limits, current value and Reset; [1.2](#12-what-supervisors-may-do)), and **Config health**: the start-up check, with a **Check again** button |
| **Live** | Every live run and unit, with the controls to recall, end, add time or split a unit, and the **Refused** tab: mission starts the server refused and why ([5.15.3](#5153-live-runs-units-and-anti-farm)) |
| **Settings** | Every setting of `config.lua` and `blocks.lua`, changed in game, with a change history ([2.6](#26-change-any-setting-in-game-the-settings-screen)) |
| **System** | Storage, backups, the webhook states, recent console problems, the other resources and the nightly clean-up ([5.15.5](#5155-system-departments-and-settings)) |
| **Audit Log** | Every supervisor and admin action, with filters and a CSV export |
| **Testing** | Optional: every mission and location with its test result, test runs, testers, and an area coverage table ([5.13](#513-testing-tools)) |

**Home** is where the panel opens: a dashboard read in one request, every minute and again a moment after a run,
mission or count changes. It only reads; every number opens the screen where you act on it.

- **Live now**: **Officers on duty** (with each department's count under it; opens Departments), **Runs going**
  (opens Live, with the first six runs as chips; only with the `liveRuns` admin key), then the queues waiting for
  you: **Flagged runs to review**, **Profiles to review** and **Open disputes** (each opens its Review tab; flagged
  runs count one per run, your own left out, every one counted), **Stuck payments** (Money → Payments) and **Open
  player suspect cases** (Real suspects; only while you have that screen). A queue with something in it has an
  orange edge.
- **Alerts**: **Problems** (System → Problems), **Refused starts today** (Live → Refused), **Config health
  warnings** (Permissions → Config health; checked again at most every 30 seconds for Home) and **Missions the last
  load refused** (Missions).
- **Shortcuts**: the tiles `Config.AdminUi.homeShortcuts` names, in its order (Admin UI → **Settings**). Shipped:
  **Make a new mission**, **Turn missions on or off**, **Change pay**, **Give or take points** and **Quick
  settings**. Also available: `live` (Running now), `review` (Review) and `activity` (Activity log); `{}` shows no
  shortcuts. Four tiles do the job right there: **Turn missions on or off** (type part of a mission's name, flip its
  switch, or open its locations and flip one), **Change pay** (find a mission type or a mission, enter the amount and
  a reason), **Give or take points** (find the officer, enter the points, below 0 takes away, and a reason; from 500
  points up you also type their citizen ID) and **Quick settings** (find an everyday setting and change it there,
  with the same checks as the Settings screen). **Open** on each tile opens the full screen.

Under the reason box of every **Set payout** (Money, Home, a mission's drawer), **Give or take points** (Home,
Leaderboards, Officers) and **Quick edit** sit ready-made reasons: **Balance change**, **Event** and **Correction**.
A click fills the box; you can still type your own. Change the list in `Config.AdminUi.reasonChips` (Admin UI →
**Settings**, up to 8 reasons of up to 60 characters); `{}` shows no buttons.

**The sidebar** is organised by job: Home on top, then six groups, each with a one-line description:

| Group (with its one-line description) | Screens in it (plain name, old name) |
|---|---|
| **People**: officers, departments, who can do what, and the boards | Officers; Departments; Who can do what (Permissions); Leaderboards and Seasons and challenges (under More) |
| **Missions**: NPC missions, the Mission Builder, the runs going on now, map markers and tests | Missions (with the Mission Builder tab); Running now (Live); Map markers; Test tools (Testing) |
| **Real players**: real players as suspects | Player suspects (Real suspects; the whole group shows only while live crimes or volunteers are on) |
| **Money**: pay rates, rewards, every payment made and the department funds | Money (Pay rates, Rewards, Payments and Department funds tabs) |
| **Review**: flagged runs, profiles, disputes, corrections and the activity log | Review (Flagged runs, Profiles, Disputes and Corrections tabs); Activity log (Audit Log) |
| **System**: settings, storage, backups and problems | Settings; Server health (System: Storage, Backups, Webhooks, Problems, Integrations, Clean-up tabs) |

The rarely used tools fold under **More**; while it is folded its badge adds up theirs, so nothing waiting is hidden,
a link or notification that opens one of them unfolds it, and the panel remembers whether you left it open.

**One search for everything.** The **Find a screen, officer, mission or setting** box over the sidebar (press
**Ctrl+K** anywhere in the Admin UI to put the cursor in it) lists, under a heading each: the **screens and tabs**
whose name, old name or group matches (Mission Builder, Flagged runs, Pay rates, Backups, ...), up to five
**officers** (name, callsign or citizen ID; a click opens the officer), up to five **missions** (a click opens the
mission's drawer on the list), up to six **settings** (a click opens Settings on that setting) and last **Search
settings for "..."**, which opens Settings with your words in its search box. Enter opens the first line. The missions
and settings load once, when you start typing; the officers are asked once you stop typing. A breadcrumb over each
screen (Home › group › screen) shows where you are; click Home to go back. The title inside each screen uses the same
plain name (Running now, Mission pay, Who can do what, ...). Every screen keeps its permission, and a group with
nothing you may see is not shown.

**The Money screen.** Admin UI → **Money** holds every money tool as four tabs: **Pay rates** (the old Payouts
screen), **Rewards** (every feature that pays), **Payments** (every payment made, with its row actions) and
**Department funds**. Home's Change pay tile, the Stuck payments tile and the Leaderboards stuck payments link open
the right tab, and the search box finds Money by the old names (Payouts, Rewards, Payments). Every action, permission
check, audit row and money-tool switch is the same as before.

**Long lists and faster screens.** Payments made gets its totals in the same request as the list, so the screen opens
with one request. In every tablet UI, a scrolling table of more than 100
rows (such as the Admin UI's Leaderboards board, the officer Leaderboard or the supervisor Department screen's
Officers tab) draws only the rows in view and the next ones as you scroll, and the Settings search results start with
60 rows and add more as you reach the end. The department and mission desk dialogs (Admin UI -> System) show their
everyday fields open and fold the rest (colours, logo, officer options; box size, rotation, prop) under a **More
options** button, and so does **Void runs…** (Officers, Leaderboards, an operation's history: the mission id,
Include awards and Strike; one you set stays open). The Supervisor UI's **Mission controls** folds the rarely changed
controls in each group (abandon cooldown, no repeat, start, ready check, time limit, idle check, unit size, staff call
wait, boards, review rules, the happy hour and twist multipliers) the same way; a control that is set always stays
open. Each screen remembers on that computer whether More was left open, and so does the Mission Builder's **More
settings** of a block. One setting stays:

| Setting | Shipped | What it does |
| --- | --- | --- |
| `Config.AdminUi.pageSize` | `0` | Rows per page (10-200, for example 50) on the Activity log, Payments made, Officers, an officer's runs on Leaderboards and the Player suspects cases. The server sends one page at a time. `0` keeps each list's own size (Activity log 50, Payments made 25, Officers 25, the last 100 runs, every case at once). The case filters on Player suspects work on the page shown. |

### 5.4 The missions

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

- **Location names** say where the place really is (for example Traffic Enforcement's Bay City Incline, Pacific
  Bluffs and Capital Boulevard, Rancho, the raids' hideouts and labs). Traffic Enforcement's two city corridors
  (Bay City Incline and Capital Boulevard) are posted at 60 km/h, so the violator does 80-105 km/h there; its
  highways stay at 90-110. Warrant Service #2 (Forum Drive, Strawberry) is Franklin's aunt's house and #5 (Sandy
  Shores) is Trevor's trailer from the story.
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
  `Config.NpcCombat` ([2.8](#28-how-hard-npcs-fight-back)).
- **Downed**: a downed officer has Failed. With no EMS on duty they are picked up after 15 seconds and taken to a
  drop-off point. With EMS on duty, an EMS request is sent for them.
- Custom missions from the Mission Builder join their type's pool when they are published.

### 5.5 Dispatch: mission calls

The tablet posts its own NPC calls every one to two and a half minutes (`Config.MissionCalls`). A call shows a code,
a radio-style title, the type, a priority (Tactical P1, Investigation P2, Patrol P3), an area and a countdown. It
never names the mission. The first unit leader (or solo officer) to claim it gets a random mission of that type in
that area. Nearby units get the first 15 seconds. Reaching the start fast earns +10% points (rapid response).
Mission calls never go to sc-dispatch. Supervisors and admins can withdraw a call, page a unit or create a call.
With the **Push a chosen mission** Mission control on, a page may name one mission for that unit alone; its leader
accepts or declines it.
Staff-posted calls wait 2 minutes between them (a department's **Wait between staff calls** Mission control may
change that); an admin may **Post anyway** with a reason. A department may also get its own **call lane** (Mission
controls → Calls, [1.2](#12-what-supervisors-may-do)): extra calls only its officers see and claim.
Calls are kept in memory: after `restart Crimson-Police` a call that was still open shows as **Lapsed** and a claimed
call whose run the restart dropped shows as **Ended by a restart** in the dispatch history and the Supervisor UI
(the run itself leaves no row, pay or cooldown); the tablet posts new calls as usual.

### 5.6 Police actions and custody

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
  contact key ([README 6.2](../README.md#62-keys)) and on the Contact panel.

### 5.7 Raids

**Drug Lab Raid** and **Gang Hideout Raid** are Tactical missions for 2–4 officers. Each run can roll different
behaviour and spawns, and the Active Mission screen shows an intel line so the unit knows what to expect. The crew
is already in place while you drive in and stack up: placed away from you (`Config.Spawning`), calm and unarmed until
the breach, when they all arm and fight. Shoot one, or walk up to one away from the doors (`stageWakeRange`), and they
wake early.

### 5.8 XP and levels

Every point an officer earns is also XP. XP gives a level from 1 to 50, then a prestige star for every 10,000 XP.
Level names (`Config.XPLevels`): Probationary, Patrol Officer, Senior Patrol, Veteran and Elite. Levels are for
show only: they never change the Qbox rank, pay or missions. They unlock looks (picture presets and accent colours),
and an optional level-up item if you set one in `Config.Rewards.levels`.

### 5.9 Leaderboards

Four boards: Weekly (resets every Monday), Monthly, Season and All-time (all-time XP). Filters by type, unit,
cross-department and department. "Rank by" points, missions, arrests, impounds, citations, rescues, mission calls
or judgement (the share of best decisions). Officers need 3 finished runs in the period to show. The top 25 show,
plus your own row. Cash is never shown. Officers can hide their name in their profile.

### 5.10 Department challenge and seasons

An admin starts a season (`/CrimsonPoliceAdmin season start Summer` or Admin UI → **Seasons & Challenge**) and ends
it when they like (8 weeks is suggested). During a season the departments compete: by default the score is the
average season points per active officer, so a small department can win. Every Monday a weekly bounty is picked at
random (for example "Most Tactical missions"), and the winning department gets +10% of its challenge points that
week. The winner gets a "Summer Champions" banner (named after the season), a trophy badge for its officers with 3
or more finished runs, and a Discord post (when `cp_webhook_board` is set).

### 5.11 Disputes, flags and suspensions

- **Flagged runs**: runs that look wrong (impossible speed, outside help, an officer who wasn't there) are flagged.
  Their points and cash are held until a supervisor or admin approves or voids them.
- **Disputes**: an officer can dispute a flagged, voided or failed run from **Profile & History** within 48 hours.
  Flagged or voided runs go to supervisors of the run's departments; failed runs (for example a bug) go to admins.
  If no supervisor can answer, admins get it. The answer is final.
- **Automatic suspension**: 3 voided runs in 30 days suspend the officer from Crimson-Police for 7 days
  (`Config.AntiCheat`).
- Admins suspend by hand in Admin UI → **Officers**, or with `/CrimsonPoliceAdmin suspend <citizenid> <days> [reason]`.

### 5.12 Mission Builder

Supervisors (Supervisor UI → **Mission Builder**) and admins (Admin UI → **Missions** → Builder) make new missions
in game, with no coding:

**New mission** opens a 4-step wizard, about 8 clicks for a
mission. Every New mission does it in one press: the Mission Builder list, the **New mission** button at the top of
Admin UI -> Missions (from any tab, also while a mission is open: its edit lock is released and an unsaved change kept)
and Home's **Make a new mission** tile.

1. **What**: pick a template card (a built-in mission's objectives, team, times, bonuses and penalties, none of its
   locations; `Config.Builder.templates`) or **Start from scratch** with a mission type.
2. **Where**: stand at the spot and press **Use my position**: the start goes where you stand, the tablet stays
   open, and the mission is named after the template and the street there, e.g. "Gang shootout - Vespucci Blvd"
   (a name you type is kept).
   **Fill the points for me** lets the game place every missing spawn point around the start (as **Fill N for me**
   below). Points the game cannot propose (a marker, a route) are listed with **Add here**, **Place** or
   **Record route**. **Add another location here** adds a location with its start where you now stand.
3. **Check**: what still stops publishing, in plain words; **Fix** opens the full editor at that spot. **Test it
   now** is optional.
4. **Publish**: the same checklist and "Publish?" confirmation as the full editor.

**Open the full editor** is on every step (the same draft); on the first step it opens the New mission dialog.
The full editor's steps are:

1. Pick up to 6 objective blocks (fight waves, pursuit, escort, search an area, rescue, skill check and more).
2. Fill in the details: name, type (it sets the points and pay), difficulty, officers, time limit, cooldown and
   which departments may get it. There is no payout field. Only admins can add mission items
   ([1.3](#13-mission-builder-permissions)). A new mission starts with the team size of its type
   (`Config.Builder.defaultTeam`: 2 officers for patrol, training and investigation, 4 for tactical), so a patrol is
   tested at the Reinforced tier, not Heavy.
   Details shows the name, type, difficulty and team size; the description, bonuses, times, departments, vehicle
   penalties and items sit under **More settings** (closed until you open it). Each objective's **Block settings**
   work the same way: a shootout shows Waves, Enemies per wave, Weapons and Difficulty (Easy, Normal, Hard set the
   enemies' aim, armour and health inside the ranges of `config/blocks.lua`), and **More settings** holds each
   wave's own count, the next-wave timing, ped models, aim, armour, health, behaviour, the boss and traffic, plus
   "Flag runs finished faster than" and "Officers must stay within". A setting with an error opens it.
3. Place spots in the world and record road routes by driving them. **Set start here** and **Add here** (or
   **Set here**) on the Locations step put the point where you stand, or where your vehicle is, with your heading:
   the tablet stays open and the spot is checked like an aimed one (no-build zone, water, ground, room for the ped
   or vehicle, distance from the start). `Config.Builder.useMyPosition = false` hides these buttons.
   **Fill N for me** on a row of hostile spawn points (people or vehicles, once the start is placed) lets the game
   propose the missing points: around the start, never inside its keep-out (the arrival circle plus `spawnMargin` for
   armed NPCs), apart by the key's spacing, on safe ground (people on walkable ground, vehicles at the side of a road),
   each one checked like an aimed spot. They show as dashed rings on the map: **Keep** adds them, **Try again** proposes
   others, **Place by hand** opens the placement tool. Stand near the location first: the game only knows the ground
   close to you. `Config.Builder.autoFill = false` hides the button.
   **Move the whole location here** (next to the location's name, once its start is placed) moves a location to
   where you stand, e.g. a copied Gang Shootout's location 1 to a yard of your own: the start goes where you stand and
   every point of the location moves with it by the same distance. Each moved point is put on the ground there and
   checked again like an aimed spot (no-build zone, water, ground, room, the keep-out, the spacing); the ones that do
   not fit are listed under the start with why, with **Fill N for me** (spawn points: new ones replace them),
   **Place by hand** and **Leave them**. Routes only move: test drive or record them again. It is saved at once. It
   is one of the "where you stand" buttons: `Config.Builder.useMyPosition = false` hides it too.
   Under the map, the point list has one row per point (its number, kind, distance from the start and, for kerb
   spots, the street) with **GPS** (a waypoint to it), **Set here** (moves only that point to where you stand) and
   **Delete** (removes only that point, saved at once). Pointing at a row rings its dot on the map. Admins (and
   ranks granted in `Config.Permissions.builderTeleport`) also get **Teleport** on each point
   ([1.3](#13-mission-builder-permissions)).
   **Show on map** (next to the location's name) closes the tablet and opens the pause map with a dot on the
   location's start, each spawn point and each checkpoint, so you can see it sits where you meant (at the cabin, not
   in the sea). **All locations** (under the list of locations) does the same for every location's start. The dots
   are only on your map and go when you open the tablet again.
4. Test it privately if you like. **Testing is optional**: a draft can be published without a test (the tablet asks
   "Publish without testing?" once). Only when `Config.Builder.requireTestToPublish = true` must a supervisor's draft
   pass a test first; an admin never needs one. The step bar marks **Scaling** and **Test** "(optional)" and ticks
   them while they hold nothing wrong.
5. Publish. The mission joins its type's pool, and a Lua file is written to `Crimson-Police/missions/custom/<id>.lua`
   (with a `.bak` copy of each old version). Until the first publish the id follows the name: a mission renamed
   "Grove Street Beat" publishes as `custom_grove_street_beat.lua`.

One builder edits a mission at a time (the edit lock). Leaving the editor (Back, another sidebar screen) or
publishing frees the lock; **Edit again** after a publish takes it back. Closing the tablet for a builder tool keeps it.

Every block on the "New mission" step has a name and a short description (Field contact and Process the scene
included). When a check fails, the Builder says it once, in plain words, naming the spots as the Builder names them:
for example `Location 1, Hostile spawn points: enemies must be at least 100 m from the start (its 60 m circle plus
40 m), so they never appear around the officers.`

A developer can edit that file by hand, then run `/CrimsonPoliceAdmin reload` to load the change as a new version.
Mission files are **data files, not scripts**: the server reads them and never runs them. Keep to the layout the
Builder writes: one `RegisterMission({ ... })` holding plain values (text in quotes, numbers, `true`, `false`, `nil`,
`{ ... }` tables, and `vec3(x, y, z)` / `vec4(x, y, z, w)` with plain numbers), plus `--` comments. Sums (`10 * 60`),
joined text (`'a' .. 'b'`), variables, `local`, functions, loops and a key written twice are refused. The console line
and Admin UI → **Missions** → **Load result** name the file and the line of a refused file, for example
`missions/custom/night_beat.lua:12: a mission file holds only RegisterMission({ ... }) with plain values (no code,
variables or sums) near '*'`. A refused hand edit is not taken in: the mission (custom or an edited built-in) keeps
playing its last published version until the file is fixed. Nothing can be placed in `Config.Builder.noBuildZones`
(stations, hospitals, the prison, Crimson-Arena).

Admins can also open any **built-in** mission in the Builder and edit it; the edit replaces the built-in under the
same id and **Reset to original** brings the shipped file back ([5.15.2](#5152-missions-and-the-mission-builder)).
While `Config.Builder.enabled = false` the Builder is off for supervisors only; admins keep it.

### 5.13 Testing tools

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

### 5.14 Rules to tell your officers

- Real RP first. When a real call comes, take it: responding ends the mission with no penalty.
- Don't mark responding just to escape a bad mission: un-marking within 60 seconds counts as a normal abandon.
- Follow the GPS route to the start. Leaving it ends your run (unless you set `Config.Route.required = false`).
  If your partners start before you get there, your GPS switches to the objective: join them there.
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

### 5.15 Full admin control

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

#### 5.15.1 Officers, points and boards

**Officers** is the search and the officer's record. The server-wide lists are on **Review**: **Flagged runs**,
**Profiles** (every pending picture, bio and profile report, and the banned-words list), **Disputes** (every open
dispute) and **Corrections** (every bulk void, retirement, record move and season reopen, each with **Undo**). Search
finds officers by name, callsign or
citizen ID and can filter by department, online, suspended, retired, off the boards, needs review, open dispute and
flagged run. An online character who never finished a run is found by typing their citizen ID.

On an officer's record:

- **Points**: their week, month, season and all-time points and rank. **Give or take points** adds points or takes
  some away (−10,000 to +10,000, a reason each time). It is a new line in their history, never an edit of an old run;
  to undo it, void that line. A deduction can never take their season points or XP below 0, and from 500 points up you
  type their citizen ID to confirm (`AdminControl.adjustConfirmAbove`). `AdminControl.adjustDailyLimit` caps what one
  admin may adjust per day (all characters of one player together); `AdminControl.pointAdjust = false` turns
  deductions off.
- **XP**: **Check XP** compares their stored XP with what their runs give; **Fix** writes the runs' value.
- **Streak**: the live streak, its multiplier and grace day. **Recalculate** rebuilds it from their runs; **Forgive
  days** covers missed days (server downtime) once a day, up to `AdminControl.streakForgiveMax` days.
  **Make available again** gives back today's first-run bonus, once per officer per day.
- **Goals**: today's and this week's goal; **Mark complete** pays a goal a bug blocked (never twice in one period).
- **Look**: **Reset look** (appearance, accent and size back to the defaults) and **Let them edit now** (clears the
  profile change cooldown). Their "hide my name" and "mute calls" choices are shown, never changed. **Own options**
  lists the My options choices they saved with the character (label: value; this-PC choices are not seen);
  **Reset options** (reason, audited) puts every one back to their department's default, at once if they are online.
- **Badges**: how each badge came (earned, granted or blocked). **Grant** keeps a badge whatever the runs say,
  **Revoke** takes one away for good, **Back to automatic** lets the runs decide again, **Re-check** recounts them.
- **Record**: **Refresh from Qbox** (callsign, rank and name come from Qbox and are never edited here), **Keep off
  the leaderboards** (a staff test character; their runs still count for their department), **Void runs…**,
  **Reset progression**, **Retire** / **Unretire** and **Move record…**.
- **Runs** tab: their whole history, the archive included, 25 per page with filters. Open a run to see its debrief,
  everyone on it, its dispute, the bank transaction ID of its payment and the goal rewards it completed, and to
  **Void** it (as a correction or as a strike, for everyone on it, with its goal rewards), **Restore** it, change the
  kind of a void, or **Flag for review**.
- **Suspend** also takes an exact date and time, and the record shows the reason. An SC-Dispatch suspension is
  shown but is changed in SC-Dispatch only.

Voids and restores:

- **Void runs…** voids every run of an officer (or a department, a mission type, a mission or an operation) between
  two dates as **one batch**. The preview lists exactly what goes; type `VOID <number>` to start. Runs you or another
  of your characters took part in are always left out. A bulk void is a **correction** by default (no strike towards
  the automatic suspension); switch on **Counts as a strike** for cheating. **Corrections → Undo** puts the whole batch
  back, including cash that was only waiting because of it. At most `AdminControl.bulkMaxRows` rows per batch.
  While a bulk job runs, its progress bar moves every `AdminControl.jobProgressEveryMs` (500 ms); the start and the
  end always show at once.
- **Refused mission starts**: the server remembers the last `AdminControl.refusalsKept` (200) mission starts it
  refused (who tried, the type or mission, and why, such as on a run, in the arena or the maintenance lock) for
  admins: Admin UI → **Live** → **Refused** lists them (time, officer, mission or type, and the message the officer
  saw), and Home → **Alerts** counts today's. Memory only: a restart empties the list.
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
in the flagged panel. **Give or take points** works as on the officer's record. The **Recognition** tab shows exactly
what officers' Home shows, the last four closed weeks with their Officer of the Week (**Recount** after a void moves
the badge, **Post again** reposts the top 3 to Discord) and the **staff notices**: short plain-text notes on Home for
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

#### 5.15.2 Missions and the Mission Builder

Everything below is in Admin UI → **Missions**. Supervisors keep the Builder as it was and get none of these tools.

**One page per mission.** Click a mission in the catalog (or its **Open** button) and a drawer opens on the right with
everything about it: the mission's on/off switch and each location's switch (with **Reset to default**), its payout
(the same as Payouts → Missions: set an admin payout with a reason, or **Back to the type payout**), **Quick edit**
for a built-in, its test status per location (**Open Testing** for the full screen), and every action as a button with
its name: **Edit in Builder**, **Duplicate**, **Launch**, **Publish**, and under **Expert actions** **Compare**,
**Versions**, **Copy as Lua**, **Fold**, **Reset to original**, **Change owner**, **Archive** and the rest. The
catalog rows have no icon-only buttons. The drawer has no setting of its own and uses the same server actions as
the catalog.

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
- **Quick edit** (in the mission's drawer) changes a built-in's cooldown, time limit and time to reach the start
  (typed in minutes: 20 is saved as 20:00), and its NPC models, cars and weapons (by their plain names), without the
  Builder. The values apply on top of an edited version too; **Fold Quick edit values into the edit** makes them part
  of it.
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
start or reload, with the reason. The same appears as the `missions` line in Permissions → Config health. A mission
file that did not load also stays in the catalog as a greyed **Not loaded** row with the reason in plain words (for
example "Time limit must be 1 to 60 minutes."); **Show the problem** opens the file name and the loader's own text.
Fix the file (or remove it), then press **Reload mission files**.

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

#### 5.15.3 Live runs, units and anti-farm

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

- **Lift ban** (shown above the boxes while a supervisor's mission ban is in force, with who set it, why and the time
  left; [1.2](#12-what-supervisors-may-do)): the officer can take missions again at once. Works also while the
  `missionBan` control is switched off. Needs a reason.
- **Clear** one type's or one mission's cooldown, or **Clear every cooldown**: at most
  `Config.AdminControl.cooldownClearsPerDay` (3) per officer per day, and not while they are on a run. A restart
  keeps the clear.
- **Allow more today**: 1 to `extraRunsMax` (10) more completed missions than the daily limit, once per officer per
  day, until the daily reset. The hourly limit and each type's own limit stay.
- **Another boss attempt**: once per officer per week. Voiding a bugged boss run also gives its attempt back.
- **Treat as a normal abandon**: a free abandon becomes a normal one, so the type and mission cooldowns start now.

**Missions → Today** shows today's Type of the Day, whether the Weekly Boss is on today and which twists your officers
may choose, with each one's bonus. **Change today's type** picks another type or none for today only; at the daily
reset the normal roll is back, and a restart keeps the choice. A twist is switched off, or its bonus changed, in
**Settings → Events → twists**.

Every one of these asks for a reason, goes into the audit log (cooldown, extra-run, boss and abandon changes post to
the flags webhook; run and unit changes to the operations webhook) and tells the officer when they are online. No
admin can use them on a run or unit they (or another of their characters) are part of, or on one of their own
characters. Setting a limit in `Config.AdminControl` to 0 switches that tool off.

#### 5.15.4 Payments, item rewards and department money

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

**Payouts** has two more buttons: **Let supervisors change it again** (keep the amount, and supervisors may move it
again within their range) and **Adjust all** (raise or lower every type payout and/or mission payout by a percentage
or an amount, with a preview of every old and new value; type `ADJUST`). A stored payout outside the current payout
range is marked.

**Leaderboards → Item rewards** gains filters (officer, status, source, dates) and buttons: **Resolve** a reward
stuck while being given (the officer must be online; if the item is in their inventory it was given; if not, it
counts as given unless you type `LOCKER` to put it back in the locker), **Deliver now**, **Cancel**, and **Take back**
(only with `Config.Rewards.allowTakeBack`, ships off: removes exactly that item from an online officer, also food
with a best-before time and bags, whose details ox_inventory fills in when it gives them). Settings →
Item rewards has a pool editor with an item picker (forbidden items left out) and the expected items and value per run
at each tier; every change is checked on the server, so the raw editor can't add a weapon either.

**System → Clean-up** shows the last nightly clean-up and **Run clean-up now** (admins, once per 10 minutes). The
clean-up never archives a run whose money or item rewards are not finished, and it waits while a bulk change runs.

#### 5.15.5 System, departments and settings

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
  `Config.Backups.daily = true` makes one at every daily reset. The backup list (`index.json`) and each backup's
  manifest are saved as a `.tmp` file first and then swapped in, so a full disk or a crash never empties the list; if
  `index.json` is lost anyway, the list is rebuilt from the manifests (one console line). **Restore** shows what it
  replaces first, makes an automatic backup, and needs the typed word `RESTORE`; then restart Crimson-Police. A
  restore never takes money back: a payment made after the backup stays paid, a given item reward stays given, pay
  still owed to an officer (waiting for them to log in, held or unfunded) is kept even when the backup is older than
  it, a void or Restore run made since stays as it is now, a record moved since stays with the new character, and the
  audit log, the settings history, department funding and the money switches are kept as they are now. The newest
  backup and the latest automatic one can't be deleted, and the backup you restore is never removed by keep N while it
  is put back (even the oldest of a full list). A damaged backup is refused before anything changes. If a restore
  stops part way, the money state is put back and payments, new runs and claims stay held, also after a restart, until
  a restore works: the banner names the automatic backup to restore (`Config.Backups.holdAfterFailedRestore = false`
  lets a restart end that lock instead).
- **Webhooks**: which Discord webhooks are on, and the exact server.cfg line to paste for each (with **Copy the
  line**). Webhook links are only ever set in server.cfg and are never shown in game.
- **Problems**: the last 200 warnings and errors since the start, by module. Webhook links, passwords and licences
  are cut out.
- **Integrations**: every resource Crimson-Police works with (running or not, its version), the checklist of
  [4](#4-settings-to-check-in-your-other-resources), and Crimson-Arena (running, players in the arena, its two
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
  while no run is going. **Officer options** (on Edit): per My options choice, **Allowed** (as global, yes or no)
  and **Default** (as global or a value) for this department's officers only, saved as
  `Config.Departments.<key>.officerOptions` and used the next time they open the tablet. For example FIB → HUD side →
  Allowed: no, and FIB officers no longer see that row; they keep the default.
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
  `Cash.source` to the department accounts shows each account's balance and the pay it would then owe; and the weekly
  bounty kinds change the running season. **Badges** has **Re-check everyone's badges**. Next to the reset hour and
  the week start, the screen shows when the next daily and weekly reset happen.
- **History** keeps the full old and new value of every change; **Revert** puts the old value back (it asks again
  when the setting changed since). **Export / Import** moves your settings to another server: you see every change
  first, locked and unknown settings are skipped, and an import never turns a money tool on.
- Config health lines (Permissions and Settings) have **Open setting** or **Copy the line** where one fixes them. The
  retention can't go under 30 days for the audit log or 3 months for archived runs; `requireItem` needs a tablet
  item; the Admin UI text must stay readable on its background.

**Audit Log**: the action filter has a **Cash actions** choice (every money tool at once); filter also by target,
role, reason text and one player (every character: click the people icon of a row), click a target to see only it,
**Export in parts** of 5000 rows, and **Save to server** (`saves/exports/audit-<time>.csv`).

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

## 6. Real suspects: live crimes and volunteers

Two optional ways to put real players opposite your officers. Both ship **off**, and while they are off nothing
here changes anything:

- **Live crimes** (`Config.LiveCrime`): when a crime script (Crimson-Contracts) reports a crime with a crew, it
  shows on the Dispatch screen as a red **LIVE** call. The unit that claims it works a live case at the reported
  place: **Respond to the reported scene**, **Secure the scene**, then **Detain and book the suspects**. The suspects
  are the real crew members.
- **Volunteer suspects** (`Config.Volunteers`): a player who is not on police duty types `/crimsonheat` and
  volunteers for an hour. When officers take a mission whose suspect a player can play (Warrant Service's wanted
  person, Street Race Bust's driver, Manhunt's fugitive), he gets a yes/no pop-up; on a yes he plays that suspect
  instead of the NPC.

The rules both share are in `Config.RealSuspects` (contact range, cuffs, bookings, the anti-farm caps). Every key
is in Admin UI → **Settings** with its description. Staff follow each case on Admin UI → **Real suspects** (under
**More**; admins with the `antiFarmOverride` key).

### 6.1 Owner checklist

Try each step on a test server first, with a second account as the suspect.

Live crimes:

- ☐ Crimson-Contracts sends its lifecycle events: `ContractsConfig.LifecycleEvents = true` in its own config.
  Crimson-Police never needs it; without it there are simply no LIVE calls.
- ☐ `Config.LiveCrime.sources` lists the scripts allowed to report a crime (shipped: `crimson-contracts`). Any
  other script's report is ignored with one console warning a minute.
- ☐ `Config.LiveCrime.types` says which crimes become LIVE calls and whose mission type points they use (`false` =
  never). Admin test contracts are never LIVE calls.
- ☐ `Config.LiveCrime.maxLiveRuns` (2) fits how many officers you have; `caseTime` (1800 s) is the longest case.
- ☐ Points only: a live case pays no cash and rolls no item rewards (`Config.LiveCrime.cash` and `items` stay
  `false` unless you decide otherwise; switched on, it pays its mission type's payout).
- ☐ Turn it on: `Config.LiveCrime.enabled = true` (config.lua, or Settings: no restart needed).

Volunteers:

- ☐ Pick who may never be a suspect: admins are left out (`Config.RealSuspects.excludeAdmins = true`), and so is
  anyone with the ace in `Config.RealSuspects.excludeAce` (`add_ace identifier.license:xxx
  crimsonpolice.realsuspect.exclude allow` in server.cfg).
- ☐ Turn it on: `Config.Volunteers.enabled = true` (config.lua, or Settings: `/crimsonheat` appears without a
  restart).
- ☐ Pick the mission types or missions a volunteer may play: `Config.Volunteers.modes` (per type) or
  `Config.Volunteers.missionModes` (per mission id). `'players_when_available'` is the safe start: the unit leader
  ticks **Real suspect OK**, a volunteer who fits is asked, else the NPC plays. `'players_only'` offers the
  type only while a volunteer is free. While every mode is `'npc'`, nothing changes.
- ☐ Admin UI → **Permissions** → **Config health** shows no warning about a mode.
- ☐ Points only: `Config.Volunteers.payCash` and `payRewards` stay `false` unless you decide otherwise. Volunteers
  are paid only with `Config.FeatureRewards.suspect` on (3.12, fair cases only); another script can reward them too
  from the `volunteerEnded` event ([9](#9-exports-for-other-scripts)).

Both:

- ☐ Share the rules in [6.2](#62-rules-for-cases-with-real-suspects) with your officers and your players
  (Discord, the server rules page) before you turn anything on.
- ☐ Tell your staff where the case timeline is (Admin UI → **Real suspects**) and what the three tools do: **Block
  pair**, **Exclude** and **Suspend** (each needs a number of days and a reason, and is in the audit log). **Lift**
  ends one early and **Clear strikes** (Volunteers tab) clears a volunteer's strikes and strike block, each with a
  reason in the audit log (`Config.RealSuspects.staffLift`, `Config.Volunteers.staffClearStrikes`). The screen shows
  character names next to citizen IDs (`Config.RealSuspects.staffNames`) and weapon names in the damage ledger
  (`Config.RealSuspects.weaponNames`); both ship on.
- ☐ Play one case of each kind on the test server with the in-game checklist (`docs/IN_GAME_CHECKLIST.md`, section
  Real suspects) and watch resmon: idle must stay at 0.02 ms or less.

Undo: set `Config.LiveCrime.enabled` and `Config.Volunteers.enabled` back to `false`. A case that is running ends
by its own rules; nothing new starts.

### 6.2 Rules for cases with real suspects

Paste these into your server rules next to [5.14](#514-rules-to-tell-your-officers). Your own server rules on
force, combat logging and staging still apply: these cases are real RP with real players.

For officers:

- A live case is a real crime: drive, talk and use force as you would on any real call. Code 3 and pursuit policy
  apply.
- Use the least force that works. Tase, tackle and cuff. Shooting a suspect who never had a gun, or running him
  over on foot, costs points and flags your run for review.
- The map shows where a suspect was **last reported**, never where he is. Search, ask, use the radio. Do not ask
  friends outside the case where he is.
- Never take a case against yourself, your other characters or a friend you play with. The server refuses most of
  these and flags the rest for review.
- Cuff, wait for the cuffs to hold, then book at a station or the prison. A booking far from a station does not
  count.
- Let a suspect who gives up give up. Hitting someone who is down or cuffed is never part of the job.
- Talk first. Within `Config.RealSuspects.surrender.talkRange` (15 m) of a free suspect you are told you can talk
  him down: **Talk them down** in the radial menu asks him to surrender. A suspect who surrenders and is then
  cuffed with no officer hitting him is a **Peaceful arrest** (`peaceful_arrest` in Config.Bonuses, for the whole
  unit), and staff see on the timeline who talked him down.
- The unit leader ends a case with **End case** in the radial menu once nobody is left to work.

For suspects (crew members of a live crime and volunteers):

- You chose this. Play it like a real criminal: run, hide, talk, give up. Do not log off, switch character or
  go into an instance to get away; it counts as leaving and is shown to staff.
- Volunteers: say yes only when you can play now. Get to the waypoint in time and stay in the area you are told
  to stay in. A no or no answer costs nothing; a yes followed by a no-show or walking away is a strike (3 strikes
  in a day block volunteering for a day).
- Do not stand still to be caught (AFK): an AFK catch counts for nobody and is a strike for a volunteer.
- Live crimes: you can give up at any time with `/surrender` (`Config.RealSuspects.surrender.command`) while an
  officer of your case is within `surrenderRange` (50 m), or say yes when an officer talks you down; you can always
  say no. Once you surrender, stay where you are and keep your hands empty: moving `breakRange` (10 m) away, drawing
  a weapon or getting out of the cuffs ends it, and it runs out after `holdSeconds` (120 s) with no cuff.
- No combat logging, no exploiting, no friends feeding you police positions from the tablet or the radio.
- You can stop at any time: `/crimsonheat` → **Stop** (or **Cancel this case**). It is free within
  `Config.Volunteers.cancelGraceSeconds` (60 s) of your yes and before officers reached you, a strike after that.

For staff:

- Check the case timeline on Admin UI → **Real suspects** before you decide a report. It lists the claim, the
  scene, every contact, cuff, detain, booking and leave, with the damage ledger and the flags.
- Use **Block pair** for an officer and a suspect who keep meeting, **Exclude** for a player who must never be a
  suspect, and **Suspend** for an officer who must not take these cases. Nobody reads or reviews a case he was a
  suspect in.

### 6.3 What is built in for fairness

- **No points for hurting players.** Points come from securing the scene, detaining and booking. A suspect cuffed
  while down counts only `Config.RealSuspects.neutralisedShare` (half) of a detain, one cuffed while AFK counts
  nothing, and shooting an unarmed suspect or running one over is a penalty (`rs_unarmed_shot`, `rs_ran_over`).
- **De-escalation counts.** In a live case a suspect can surrender (`/surrender`) or be talked down (**Talk them
  down**, radial menu); the suspect always chooses. A surrender followed by a cuff with no officer hit scores the
  `peaceful_arrest` line (15% of P per suspect, x his share), and the timeline names the officer who talked him down.
  `Config.RealSuspects.surrender` (on, but only while `Config.LiveCrime.enabled` is on).
- **No live position.** Officers see the reported place and, every `Config.LiveCrime.lastReportedEvery` seconds
  (60), each free suspect's **last reported** point. A volunteer driver's point moves every
  `Config.Volunteers.driverReportEvery` seconds (30); a volunteer at the door or in a search area is never on the
  map. The case card says how old the points are.
- **Consent and opt-out.** A crew member is a suspect only of the crime he chose to commit; a volunteer is asked
  first, every time, and can stop or cancel from his `/crimsonheat` menu. Players in a hospital, the arena or
  another instance, on police duty or AFK are never picked.
- **Caps against farming.** A suspect is worth points `Config.RealSuspects.maxCatchesPerSuspectDay` (2) times a day
  (in a crew, one already at the cap when the case opens gives no line; the others still do), the same officer and
  suspect meet again for points only after `pairCooldownHours` (24), and accounts that share a connection or PC are
  flagged.
- **Staff see everything.** Every case keeps a timeline, the damage ledger and the flags on the Real suspects
  screen (the last `Config.RealSuspects.casesKept`, 16, closed ones; saved, so a restart keeps them).

### 6.4 When something does not happen

| Issue | Solution |
|---|---|
| A crime gives no LIVE call | `Config.LiveCrime.enabled` is `false`, the crime's key is `false` or missing in `Config.LiveCrime.types`, Crimson-Contracts does not send its events (`ContractsConfig.LifecycleEvents`), or `maxLiveRuns` calls are up. The audit log says **Live crime ignored** with the reason |
| A crime has no suspects | Every crew member was offline, more than `Config.LiveCrime.suspectRadius` (300 m) from the crime, AFK, on police duty, in a no-start zone or excluded |
| `/crimsonheat` says it is off | `Config.Volunteers.enabled` is `false`. A player who is refused for another reason is told why (on duty, AFK, excluded, too many strikes) |
| Nobody is ever asked to play a suspect | Every mode is `'npc'`, the unit did not tick **Real suspect OK**, or no volunteer fits (listed for that suspect, not AFK, not down, no recent case with one of the officers) |
| A cuff did not count | The officer must be on the case and within `Config.RealSuspects.cuffRange` (3.5 m), and the cuffs must hold `custodyHoldSeconds` (30 s). The timeline shows each cuff and why it did not count |
| `/surrender` or **Talk them down** does nothing | `Config.LiveCrime.enabled` or `Config.RealSuspects.surrender.enabled` is `false`, the player is not a free suspect of a live case (volunteer cases have no surrender), no officer of the case is within `surrenderRange` (50 m), or the officer is not within `talkRange` (15 m) of a free suspect. A new command name needs a restart |
| A live case vanished after `restart Crimson-Police` | A restart ends every open case and its run: no row, no points, no pay, no cooldown, and the LIVE calls are gone too (a surrender in progress ends with it). The unit has to be formed again. Closed cases, their timelines, payments, blocks, strikes and your Settings changes are kept. The crime script's next crime makes a new LIVE call |
| The Real suspects screen is missing | Both features are off, the admin has no `antiFarmOverride` key, or `Config.RealSuspects.adminScreen = false` |

### 6.5 The criminal tablet

A tablet of its own for volunteer suspects (`Config.CriminalTablet`), with a dark street look nothing like
the police tablet (the same buttons, cards and tables as the police tablets, in its own colours). It ships **off** (`enabled = false`): until you turn it on, nothing changes and `/crimsonheat`
keeps its pop-up menu. It runs on volunteers, so `Config.Volunteers.enabled` must be on too.

- **Open it** with `/crimtab` (`command`, restart to rename it) or an ox_inventory item: paste the
  `crimson_criminal_tablet` entry of `items/ox_inventory_items.lua` into ox_inventory and set
  `Config.CriminalTablet.item = 'crimson_criminal_tablet'` (shipped `false`: no item). Admin UI → Permissions →
  **Config health** (and one console line at start) warns when that item is not an ox_inventory item. With
  `replaceCommand = true`, `/crimsonheat` opens the tablet instead of its menu for a player who may use it.
- **Who may use it**: `access = 'everyone'` (shipped) lets every player whose job is not a police job of
  `Config.Departments` use it. `access = 'granted'` lets only the players named by the **Criminal tablet** extra
  grant use it: Admin UI → **Permissions** → **Extra grants** (by Qbox gang and grade, department and grade, or
  citizen ID). Police on duty can never open it, and an open tablet closes when its player goes on police duty.
- **Home**: agree to the rules, tick the suspects you play and **Get on the list** for
  `Config.Volunteers.windowMinutes`; while on it: the time left, **Save suspects**, **Renew** and **Get off the list**
  (two clicks).
- **Jobs**: the question police just sent you (the suspect, the mission type, the area, how far, the time to get
  there and to answer). **Accept** is the same yes as the pop-up (the meet point becomes your waypoint); **Decline**
  costs nothing. While the tablet is open the question shows here instead of the pop-up; close the tablet and the
  pop-up comes up for the seconds left.
- **Active**: the suspect you play, the phase (get to the meet point, in position, police reached you), the time left
  to get there, your meet point, the rules and **Give up** (free right after your yes, a strike later).
- **History**: your strikes with when each runs out, a strikes block, and your past cases with how they ended (the
  last `historySize`, 20, since the last restart). **Rules**: the numbers of your server's config.
- It never shows a run, an officer or anyone's live position, and every button is checked again by the server.
- Rewards: with **Pay volunteer suspects** off (`Config.FeatureRewards.suspect.enabled`, shipped) a job shows "None
  from Crimson-Police". Turned on, the job's **Reward** line shows what a fair case pays, e.g. "$1,500 if you get away,
  $500 if you are caught", plus "Items may come with it." when its items list is set and Item rewards are on.

---

## 7. Before go-live, updating and backups

### 7.1 Before go-live checklist

- ☐ The start-up check passes: type `CrimsonPoliceAdmin check` in the console ([README
  3.4](../README.md#34-start-the-server-and-read-the-console)).
- ☐ Your department jobs exist and `supervisorGrade` is right ([README 3.3](../README.md#33-check-your-police-jobs),
  [README 4.3](../README.md#43-supervisors)).
- ☐ You and your staff can open `/CrimsonPoliceAdmin` ([README 4.2](../README.md#42-admins)).
- ☐ The payouts fit your economy ([2.3](#23-payouts)).
- ☐ Your logos are in `Crimson-Police/logos/` ([3.7](#37-department-logos)).
- ☐ On a custom station MLO, the mission desks sit in the right place, or are off ([3.2](#32-mission-desks)).
- ☐ `Config.Debug = false` for a quiet console (it ships `true` for testing), and `Config.Database.enabled` is what
  you want: `false` (as shipped) saves to the `saves` folder, `true` uses your database
  ([README 5.1](../README.md#51-the-two-switches-at-the-top-debug-and-storage)).
- ☐ You read `config/banned_words.txt` and changed it for your community
  ([2.5](#25-other-settings-you-may-want-to-change)).
- ☐ Item rewards and picture links are what you want (both ship off: [3.3](#33-item-rewards),
  [3.4](#34-profile-pictures)).
- ☐ NPC difficulty fits your officers: `Config.NpcCombat` ships with no automatic weapons, accuracy at most 18 and
  half damage ([2.8](#28-how-hard-npcs-fight-back)). Lower = easier.
- ☐ Optional: try the missions you care about. The built-in locations were placed from map data and checked by
  tests, but not driven in game. Admin UI → **Testing** runs any mission at any location; a location that does not
  fit your map can simply be switched off ([2.7](#27-turn-missions-and-locations-on-or-off)). Nothing needs a test.
- ☐ Share the rules in [5.14](#514-rules-to-tell-your-officers) with your officers, and the Detach tip in
  [4](#4-settings-to-check-in-your-other-resources) with your dispatchers.
- ☐ Your anti-cheat allows Bomb Disposal's harmless explosion ([4](#4-settings-to-check-in-your-other-resources)).
- ☐ Real suspects stay off (`Config.LiveCrime.enabled` and `Config.Volunteers.enabled` ship `false`) until you
  went through the owner checklist and shared the rules in [6](#6-real-suspects-live-crimes-and-volunteers).
- ☐ Make one backup and try one restore on a test server: Admin UI → **System** → **Backups**
  ([7.3](#73-backups)). A restore ends with "Restart Crimson-Police now"; do that from txAdmin.
- ☐ The money tools that ship off (`Config.Cash.allow*`, `Cash.restoreForfeited`, `Rewards.allowTakeBack`): leave
  them off, or try each one first on a test server with Renewed-Banking, ox_inventory and Qbox, as
  [5.15.4](#5154-payments-item-rewards-and-department-money) says.
- ☐ The admin limits fit your server: Admin UI → **Settings** → `AdminControl` (point adjustments, cooldown clears,
  extra runs, added run time). Setting a limit to 0 turns that tool off.

### 7.2 Updating

1. **Back up first** (see [7.3](#73-backups)).
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

### 7.3 Backups

- **In game**: Admin UI → **System** → **Backups** → **Back up now** saves every Crimson-Police table, your custom and
  edited missions, uploaded logos and the banned-words file in `Crimson-Police/saves/_backups/`. It works with the
  database on and off. `Config.Backups.daily = true` makes one at every daily reset, and the last
  `Config.Backups.keep` (7) are kept. **Restore** shows what it will replace, makes an automatic backup first and
  needs the typed word `RESTORE`; then restart Crimson-Police from txAdmin or the server console. A restore never
  takes money back: a payment made after the backup stays paid, and the audit log is kept as it is
  ([5.15.5](#5155-system-departments-and-settings)). If a restore stops part way, payments stay held (also after a
  restart) until you restore the automatic backup the banner names, then restart.
- **Outside the game**, before every update:
  - **Database on**: back up your database (all the `cp_` tables), like you do for Qbox.
  - **Database off**: copy the whole `Crimson-Police/saves/` folder (it holds `_backups/` too) while the server is
    stopped.
  - Either way, also keep a copy of `config/`, `logos/` and `missions/custom/`.

---

## 8. More console lines

The console lines about storage, config.lua, missions, payments and webhooks, after the ones in [README
8](../README.md#8-troubleshooting).

### 8.1 Database and saves folder

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
| `the saves folder ... is new, so Crimson-Police starts with no data` | You switched the database off on a server that has data in the database. Run `CrimsonPoliceAdmin storage copy database-to-files`, then restart ([3.5](#35-database-off-the-saves-folder)) |
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

### 8.2 Config and departments

| Console line | What to do |
|---|---|
| `config/config.lua did not load, so Crimson-Police cannot work.` | A typing mistake in `config.lua`. The first red error above it names the line (usually a missing comma, quote or bracket). Fix it and restart |
| `Config.X is missing: config/config.lua (or config/blocks.lua) stopped at an error, or it is from an older version.` | Fix the line a red error names, or copy the missing blocks from the new `config.lua` |
| `Department <key> lists no Qbox job names in jobs: nobody can use it.` | Put your job name in `jobs = { }` |
| `Department <key>: supervisorGrade must be a Qbox grade level` | Write a number, like `supervisorGrade = 3` |
| `Qbox job <job> is listed in departments <a> and <b>; <a> is used` | A job may only be in one department |
| `Department <key>: logos/<file> is missing` | Put the logo file in `logos/` and restart ([3.7](#37-department-logos)) |
| `Department <key>: logo.file ... must be a PNG, WebP or SVG file name in logos/` | Use a plain file name like `'sast.png'` |
| `Department <key>: theme.<key> is ..., not a 6-digit hex colour` | Write the colour like `'#1f4e8c'` |
| `Config.Departments key <key> must be letters, digits or _` | Rename the department key |
| `Config.Profile.bannedWordsFile ... was not found` | Put `config/banned_words.txt` back, or set `bannedWordsFile = false` |
| `Config.Downed.dropOffs has no valid point` | Write drop-offs as `vec3(x, y, z)` |
| `Department <key>: the tablet could not load its logo ... (reported by player <n>)` | The logo file or link is broken. Check the file in `logos/`, or the `logo.url` link |
| `Config.AdminTheme.<key> is not a 6-digit hex colour` | Write the colour like `'#a4161a'` |
| `Config.Challenge.scoring <x> is not average, total or top10; using average` | Use `'average'`, `'total'` or `'top10'` |
| `Config.Challenge.bounties is empty: no weekly bounty` | Put the bounties back, or set `weeklyBounty = false` |
| `Config.Rewards <pool>: "<item>" does not exist in ox_inventory; it is turned off` | Use an item that exists ([3.3](#33-item-rewards)) |
| `[crimson-police] <n> setting(s) changed in game are in use (Admin UI → Settings)` | Normal: the settings an admin changed in game are used ([2.6](#26-change-any-setting-in-game-the-settings-screen)) |
| `the saved setting <path> was ignored (<why>): config.lua's value is used.` | A setting saved in game is no longer allowed (often after an update). Open Admin UI → **Settings**, filter **Changed**, and change or reset it |
| `the settings changed in game could not be read: ...` | The database or saves folder could not be read: see [8.1](#81-database-and-saves-folder). Until it works, `config.lua`'s values are used |

### 8.3 Missions and the Mission Builder

| Console line | What to do |
|---|---|
| `missions loaded: 19 built-in (N edited), N custom, N rejected` | Normal. "rejected" above 0 means a line above says which file and why; Admin UI → **Missions** shows the same as the load result |
| `the edited version of <id> (<file>) was not loaded, the shipped mission plays: <reason>` | An edited built-in mission broke (often a hand edit of its file). Open it in Admin UI → **Missions** → **Edit in Builder** and publish again, or **Reset to original** |
| `custom mission <id>: edited in code, saved as version <n>` | Normal: someone edited that mission's Lua file, and the edit is now live |
| `mission <id> (<file>) was not loaded: <reason>` | For a custom mission, fix it in the Builder or the file. For a built-in one, copy the file again from the download |
| `... was not loaded: syntax error: <file>:<line>: ... near '<text>'` | That line of the mission file is not plain data (often a hand edit: a sum like `10 * 60`, a variable, joined text, or a key written twice). Write the plain value, like `600`, and run `/CrimsonPoliceAdmin reload` |
| `custom mission <id>: the edited file ... was not accepted` | A hand edit broke the mission. The old version stays live. Fix the file and run `/CrimsonPoliceAdmin reload` |
| `custom mission <id>: field "<name>" in its Lua file is ignored` | Payouts can't be set in mission files. Use the Payouts screens |
| `custom mission <id> (version <n>): items skipped: saved by a supervisor ...` | That version was published by a supervisor (or before Crimson-Police recorded who published it), so its runs hand out no items ([1.3](#13-mission-builder-permissions)). An admin opens it in the Mission Builder and publishes it again to give the items back, or removes them |
| `mission <id>: objective <n> names WEAPON_SMG, an automatic weapon: its NPCs carry WEAPON_COMBATPISTOL instead (Config.NpcCombat)` | Harmless: an older custom mission (or a `Config.MissionTweaks` entry) still names an automatic weapon, and its NPCs get the weapon named after "carry". To make the line go away, pick a pistol or a shotgun for it in the Mission Builder ([2.8](#28-how-hard-npcs-fight-back)) |
| `the folder Crimson-Police/<folder> is missing: create it by hand` | Make that folder by hand. Crimson-Police ships every folder it writes (`missions/custom/` with `archived/`, `overrides/`, `overrides/archived/` and `deleted/` inside it, `saves/_backups/`, `saves/exports/`), each with an empty `.gitkeep` file, so a missing one usually means the copy left empty folders out: copy the whole Crimson-Police folder again. The server cannot create folders on Linux (FXServer crashes when it tries), so Crimson-Police never does |
| `the folder Crimson-Police/<folder> is there but the server cannot write to it` | Give the user the server runs as write access to that folder |
| `built-in mission <id> cannot be unregistered; turn it off in Config.DisabledMissions` | Use `Config.DisabledMissions` |
| `cp_type_payouts has a payout for unknown mission type <type>; it is ignored` | Harmless. A type was removed from `Config.MissionTypes` |

### 8.4 Payments, webhooks and other lines

| Console line | What to do |
|---|---|
| `row <n> unfunded: society account <name> could not cover <amount>` | Put money in that Renewed-Banking account ([3.8](#38-paying-from-the-departments-bank-account)) |
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

---

## 9. Exports for other scripts

| Export | Side | What it does |
|---|---|---|
| `exports['Crimson-Police']:OpenTablet()` | client | Opens the tablet, with the same officer checks as `/CrimsonPolice` (on duty, department job, not suspended; the item when `requireItem = true`). It works even when `access.command = false` |
| `exports['Crimson-Police']:GetDepartment(src)` | server | The department key of the player's active job (`'sast'`, `'fib'` ...) or `nil` |
| `exports['Crimson-Police']:IsOnMission(src)` | server | `true` while the player is on a Crimson-Police mission |
| `exports['Crimson-Police']:GetAvailablePolice()` | server | Read-only, for crime scripts: the number of on-duty officers who could answer a crime now (on no Crimson-Police mission with `Config.LiveCrime.availablePolice = 'idle'`, every on-duty officer with `'duty'`) and a table `{ [department] = count }`; `nil` while `Config.LiveCrime.enabled = false` (count police your own way then) |

Server-only event for other scripts: `crimson-police:server:liveCrimeEnded` (`Config.LiveCrime.endEvent = true`)
when a live case ends, with `{ resource, uid, id, key, result, reason, suspects = { [citizenid] = outcome }, caught,
officers, endedAt }`: `resource`, `uid`, `id` and `key` are the reporting script's own names for the crime, `result`
is how the run ended (`completed`, `failed`, `abandoned`), each outcome is `detained`, `booked`, `got_away`, `left`,
`void` or `stopped`, `caught` counts the detained and booked suspects and `officers` the case's officers. Listen with
`AddEventHandler` only (never `RegisterNetEvent`, so no client can send it). It carries no server id and no position.

Server-only event for other scripts: `crimson-police:server:volunteerEnded` (`Config.Volunteers.endEvent = true`) when
a mission a volunteer said yes to ends (Crimson-Police pays volunteers only with `Config.FeatureRewards.suspect` on,
3.12; another script can reward them too), with `{ citizenid, missionId, missionType, role, mode, outcome, dropout,
engaged, result, reason, officers, endedAt }`: `citizenid` is the volunteer, `role` the suspect he played (`runner`,
`driver`, `fugitive`), `mode` the mission's mode, `outcome` his outcome as above, `dropout` why his part was voided
(`no_show`, `cancelled`, `left`, `afk`, `out_of_bounds`) or `nil`, `engaged` whether officers reached him, `result`
and `reason` how the run ended and `officers` how many officers were on it. Same rules: `AddEventHandler` only, no
server id, no position.

The tablet item uses the client export `useTablet` (`export = 'Crimson-Police.useTablet'` in the item).
