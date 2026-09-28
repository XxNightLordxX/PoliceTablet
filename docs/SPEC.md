# Crimson-Police – Tablet Missions & Leaderboard Spec

Sep 28, 2026 · @John Wood

Crimson-Police is a Qbox police tablet (/CrimsonPolice) with its own custom UI. It gives on-duty SAST and FIB officers random NPC missions by mission type, pays cash through Renewed-Banking and ranks officers on leaderboards. Read Hard rules first: they override every other section, and the files in config/ override any number in this document.

## Hard rules

These rules override everything else in this spec. If another section, example or number disagrees with a rule here, the rule wins.

- Stack: Crimson-Police MUST run on Qbox (qbx_core) and MUST use only these resources: sc-police, sc-dispatch, sc-ambulance, sc-multijob, Renewed-Banking, oxmysql, ox_lib, ox_inventory and ox_target. It MUST recognise calls made by sc-npcpolice without calling it. It MUST NOT require, bridge to or edit any other resource.

- Qbox only: all framework access MUST go through exports.qbx_core, the Qbox player object it returns (for example player.Functions.AddMoney, which is Qbox's own API) and the events qbx_core fires. Crimson-Police MUST NOT use the QBCore core object (exports['qb-core']:GetCoreObject(), QBCore.Functions) or list qb-core as a dependency, even though Qbox ships a QBCore compatibility layer.

- Names: the resource folder MUST be Crimson-Police (events, callbacks and tags keep the lowercase prefix crimson-police) and the tablet MUST be titled "Crimson-Police". The officer command MUST be /CrimsonPolice and the admin command MUST be /CrimsonPoliceAdmin.

- Access: only on-duty players whose active Qbox job belongs to a department in Config.Departments MAY use the Officer UI. There are no activation requirements: no activity check, no minimum officers online and no quiet timer.

- Roles: there are exactly three roles: Officer, Supervisor (job grade at or above the department's supervisorGrade) and Admin (ace crimsonpolice.admin). There are no cadet, detective or other roles. Supervisors get the same missions as officers. Ranks and callsigns are read from Qbox, as SC-Police sets them, and are never edited by Crimson-Police.

- Mission choice: officers and supervisors MUST only pick a mission type, and the server MUST draw the mission at random. The Officer UI MUST NOT list, preview or let anyone pick a specific mission, and there is no reroll. Only three exceptions exist: the Weekly Boss event card, a supervisor or admin picking one specific mission to launch as a Cross-Department Mission, and test runs (Admin test mode, and the Mission Builder's test run of a draft), which are never saved or paid.

- Cross-Department Missions: while one is active, every department's Mission Board MUST show only that mission, and the server MUST refuse every other new mission until it is completed or cancelled. Admin test runs are the only exception.

- Teams and scaling: officers from any department MAY team up. Missions MUST scale with the number of participants, and cash MUST scale with the resulting difficulty.

- Cash payouts: every mission pays its mission type's payout × its star multiplier (the Weekly Boss pays its own event payout from config) unless an admin has set a payout for that specific mission. Supervisors MAY change a type's payout only if no admin has set it, and only within Config.Payouts.supervisorRange. Only admins MAY set a single mission's payout. Any payout an admin sets is permanent until an admin changes or clears it.

- Points: leaderboard points come from Config.MissionTypes and the scoring rules. Points MUST NOT be editable in-game, apart from an admin's logged manual award.

- Server authority: the server decides draws, scaling, points and cash. The client MUST NOT send point or cash amounts; it only reports objective events, which the server validates.

- Departments: department names, colours and logos come only from Config.Departments. Adding a department there and restarting MUST make it work everywhere with no code or SQL changes.

- Custom interfaces: the Officer UI, Supervisor UI and Admin UI are separate, custom standalone NUI built for Crimson-Police, together with its Mission Builder, mission HUD and notifications. Each shows only its own screens, and the server MUST re-check permissions on every action. The only outside UI allowed is ox_target's interaction prompts, ox_inventory's own inventory screens, and ox_lib's progress bar and skill check during missions.

- NPCs only: missions MUST involve only NPCs. They MUST NOT create SC-Dispatch calls (the one exception is the EMS request sent for a downed participant while EMS is on duty), target real players or spawn anything a non-participant can take.

- Real calls first: when a participant is assigned to, or marks themselves responding to, a real SC-Dispatch call (any call not created by SC-NPCPolice), their run MUST end at once with no penalty and no cooldown. SC-NPCPolice calls MUST NOT end a run. There are exactly two exceptions: un-marking responding within 60 seconds turns the free abandon into a normal one (type cooldown), and a call raised about a participant of the same run (their person-down, dead, EMS or panic call) does not end their partners' runs.

- No mission alerts: from the moment a participant reaches the mission start until their run ends, their mission combat MUST NOT create SC-Dispatch or SC-Ambulance alerts (shots fired, person down), and any such call that still appears in SC-Dispatch MUST be cleared automatically. A downed participant can still get EMS help.

- Route to the start: participants MUST follow the route shown to the mission start; staying off it ends their run as Abandoned.

- Downed participants: a participant who goes down has Failed their run. If no EMS is on duty, they MUST be picked up automatically (revived and moved to a drop-off point).

- Cleanup: every entity, blip, zone and mission item MUST be removed when a run ends for any reason, including disconnects and resource stops.

- Mission Builder: it runs inside Crimson-Police's own UI: on the tablet in the Supervisor UI, and in the Admin UI panel for admins. Every custom mission MUST have a mission type and MUST NOT have a payout field. Recorded routes are saved as roads, not as the exact line the builder drove. Publishing MUST write a Lua file that developers can edit.

- Code layout: each feature MUST live in its own folder under modules/, each objective block in its own folder under blocks/, and each mission in its own file under missions/, so every part can be edited and debugged on its own (see Architecture).

- Config wins: if a number in this document and the files in config/ disagree, the config value wins.

## Do not build

Everything below was considered and removed. Do not add it back, even as an option or a disabled config flag.

- Missions: traffic stops, Speed Enforcement, Traffic Control, DUI Checkpoint, Abandoned Vehicle, Suspicious Person, Range Qualification, Evidence Recovery, Rooftop Shooter, Air Support, Harbor Interdiction, and anything using cones.

- Activation: no server activity state (Quiet / Busy / Active), no priority-traffic command, no minimum officers online, no mission pause and no Expired state.

- Mission choice: no list of individual missions on the officer Mission Board, no picking or previewing a specific mission (apart from the Weekly Boss card, Cross-Department Missions and test runs), no reroll.

- Roles: no cadet, detective, FTO or supervisor-only missions, no grade-restricted mission pools, and no separate builder permission.

- Payouts and points: no in-game editing of points (only an admin's logged manual award), no point awards from other resources, no supervisor editing of single-mission payouts, and no payout field in the Mission Builder or in exported Lua files.

- Leaderboards: no manual board reset; boards are time windows, and corrections are made by voiding runs.

- Framework: no QBCore core object, no QBCore.Functions, no qb-core dependency, and no QBCore or ESX bridges.

- Integrations: no other dispatch, inventory, target, banking, medical or tablet resources; no edits to sc-police, sc-dispatch, sc-ambulance, sc-multijob, sc-npcpolice or Renewed-Banking; missions never create SC-Dispatch calls (apart from the EMS request for a downed participant); never trigger SC-Ambulance's hospital:server:RevivePlayer (it bans any sender who is not EMS).

- UI: one custom UI stack only (React + TypeScript + Vite); no ox_lib menus, context menus, input dialogs or notifications for Crimson-Police screens; no third-party tablet; no Crimson-Police tab inside the SC-Dispatch MDT.

- Rule switches: no config flag that turns off Hard rules 15–18 (real calls, alert suppression, the start route, downed participants). Their numbers are configurable; the rules are not.

## Glossary

Each term below means exactly this everywhere in the spec.

| Term | Meaning |
|---|---|
| Crimson-Police | This resource (Crimson-Police) and the tablet it adds |
| Department | An entry in Config.Departments (today SAST and FIB): its jobs, name, colours, logo and supervisor grade |
| Officer | An on-duty player whose active Qbox job belongs to a department |
| Supervisor | An officer whose job grade is at or above their department's supervisorGrade |
| Admin | A player with the ace crimsonpolice.admin; does not need to be police or on duty |
| Rank | The officer's Qbox job grade name (e.g. "Sergeant"), the same ranks SC-Police and SC-Dispatch use |
| Callsign | The officer's callsign from Qbox metadata, set with SC-Police's /callsign |
| Mission type | Patrol, Training, Investigation or Tactical; the only thing officers pick |
| Mission | One playable scenario, such as Gang Shootout; belongs to exactly one mission type |
| Built-in mission | A mission shipped with the resource, one file each in missions/builtin/ |
| Custom mission | A mission made in the Mission Builder, exported to its own file in missions/custom/ |
| Pool | The missions of a type that can currently be drawn for an officer or unit |
| Draw | The server's random pick of one mission from the pool |
| Run | One attempt at a drawn mission, from accepting the type until it ends |
| Participants | Everyone on a run: a solo officer, a unit, or everyone who joined a Cross-Department Mission |
| Unit | 2–4 officers, from any departments, doing one run together; the leader picks the type |
| Run host | The participant whose client runs the NPC AI for a run: the unit leader, or the next participant if the leader leaves |
| Start route | The GPS route from where a participant accepted the mission to its start |
| Cross-Department Mission | A specific mission a supervisor or admin launches for every department; it locks the Mission Board until it is completed or cancelled |
| Tier | The difficulty level set by the number of participants: Standard, Reinforced, Heavy, Major or Critical; if someone leaves mid-run it follows the team down |
| Medal | The Gold, Silver or Bronze result on EVOC Course and Pursuit Sim |
| Objective / block | One step of a mission; blocks are the reusable step types missions are built from |
| Road route | A route recorded in the Mission Builder by driving it, stored as road waypoints |
| Module | One feature's code folder under modules/, such as modules/cash/ |
| Real call | Any SC-Dispatch call not created by SC-NPCPolice |
| NPC call | A call created by SC-NPCPolice; its call id starts with npccall- |
| Alert suppression | The crimsonArena state bag Crimson-Police sets on each participant from the moment they reach the mission start so SC-Dispatch and SC-Ambulance skip their combat alerts |
| Downed | A participant who is dead or in last stand |
| Pick-up | The automatic revive and move to a drop-off point when a participant goes down with no EMS on duty |
| Police vehicle | A vehicle whose class or model is listed in Config.PoliceVehicles (default: class 18, Emergency) |
| Points | Leaderboard score earned by a run |
| XP | Lifetime points; sets the cosmetic XP level badge (never the rank) |
| Goal | A personal daily or weekly target, such as "Complete 2 Patrol missions", that awards bonus points |
| Base payout | The mission's admin payout if one is set; otherwise its type payout × its star multiplier (the Weekly Boss: its event payout from config) |
| Type payout | The base cash payout for every mission of a type |
| Mission payout | An admin-set base cash payout for one mission; overrides the type payout |
| Cash payout | Money each participant receives for a Completed run: base payout × tier multiplier × modifier multiplier |
| Season | An admin-started period (8 weeks suggested) with its own leaderboard and department challenge |
| Department challenge | The season contest between all departments |
| Bounty | A weekly department objective worth a bonus of 10% of the challenge points the winning department earned that week |
| Type of the Day | The mission type that earns double points today |
| Modifier | A random twist on a run that adds points and cash |
| Weekly Boss | The Kingpin mission, available Friday to Sunday on its own card |
| Flagged run | A run held off the leaderboards, with its cash held, until a supervisor reviews it |
| Voided run | A run removed from every leaderboard by a supervisor or admin |
| Dispute | An officer's request, within 48 hours, for one of their flagged, voided or failed runs to be reviewed again |
| Theme | A department's tablet colours |
| Watermark | The department logo drawn faintly behind every Officer and Supervisor UI screen |
| End reason | How one participant's run ended, stored as end_reason (for example quit, off_route, real_call or downed); the full list is in Mission lifecycle |
| Permissions | Config.Permissions: which supervisor actions are switched on. Admins can always do every admin action |
| Server run cap | The most runs that can be active server-wide at once: 12, of which at most 4 Tactical. Cross-Department Missions don't count |
| Daily reset | The hour (Config.Time.resetHour, 00:00 server time by default) when Type of the Day, daily goals, streak days and the daily cash cap roll over |
| Test run | A run started in Admin test mode, or the Mission Builder's test run of a draft: any mission, location and tier, with nothing saved or paid |
| Streak | Consecutive days with a completed run, worth +5% points each (up to +25%); one missed day a week is forgiven |

## Overview & goals

Crimson-Police is a police tablet for the quiet parts of a shift: on-duty officers pick a mission type, the server draws a random NPC mission scaled to their team, and completed runs pay cash and earn leaderboard points. There are no activation requirements, so any on-duty officer can start a mission at any time.

Names: resource folder Crimson-Police · tablet title "Crimson-Police" · officer command /CrimsonPolice · admin command /CrimsonPoliceAdmin.

Goals

- Give officers something useful and fun to do during quiet shifts instead of idling at the station.

- Reward teamwork across SAST and FIB, driving skill and procedure, not just raw playtime.

- Keep real player-driven RP as the top priority at all times.

- Give command staff visibility into activity and a fair basis for recognition.

Success criteria

| Measure | Target |
|---|---|
| Officers who start at least one mission per quiet shift | 60%+ after 4 weeks |
| Median time from a real 911/dispatch call to a unit leaving a mission | Under 10 seconds |
| Leaderboard disputes needing admin review | Fewer than 2 per week |
| Server resource time (resmon) with 30 officers on | Under 0.10 ms client, 0.25 ms server |
|  |  |

Out of scope: civilian-facing missions, missions for EMS or fire, and anything that uses real players as mission targets.

## Dependencies & decisions

Crimson-Police is built for this server's Qbox stack only. Every resource below is already installed, and its name must be used exactly as written.

| Resource (exact name) | Used for |
|---|---|
| qbx_core | Player data (citizenid, name, active job, rank, duty, callsign, metadata), job definitions, adding money. Qbox APIs only |
| sc-police | The police jobs (job.type = 'leo'), duty, and callsigns (its /callsign command saves them to Qbox metadata) |
| sc-dispatch | Real-call detection (responding and dispatcher assignments, checked against its mdt_dispatch table), clearing stray shots-fired calls, suspension checks, and its Crimson-Arena alert hook |
| sc-ambulance | How many EMS are on duty, reviving picked-up officers, EMS requests, and its Crimson-Arena alert hook |
| sc-npcpolice | Nothing is called. Crimson-Police only recognises its call ids (npccall-…) so its calls never end a mission |
| sc-multijob | Players can hold several jobs; only the active job counts |
| Renewed-Banking | Bank transaction entries for cash payouts; optional department society accounts |
| oxmysql | All database access |
| ox_lib | Callbacks, progress bars, skill checks, zones, keybinds, locales. Not used for Crimson-Police's screens |
| ox_inventory | Optional tablet item; any items a mission hands out |
| ox_target | Interacting with mission props, doors and NPCs |

The Appendix lists the exact exports and events used from each of these resources.

Decisions

| Question | Decision |
|---|---|
| Qbox or QBCore? | Qbox only (Hard rule 2) |
| Resource name? | Crimson-Police for the folder and the tablet title; events, callbacks and tags use the lowercase prefix crimson-police |
| Which tablet hosts the app? | Crimson-Police has its own standalone tablet, opened with /CrimsonPolice. It is not a tab in the SC-Dispatch MDT |
| UI? | A custom standalone UI built for Crimson-Police: React 18 + TypeScript, built with Vite |
| Which job names? | sast and fib, as used by sc-police and sc-dispatch |
| Ranks and callsigns? | Read live from Qbox: rank = the job grade name, callsign = metadata.callsign (set by SC-Police). "Rank" only ever means this; the cosmetic tiers earned from XP are called XP levels |
| Cadets or detectives? | Not roles on this server. Every officer in a department gets the same missions |
| Supervisor missions? | The same missions as officers. Supervisors can also see the full list of missions and launch Cross-Department Missions |
| Can departments team up? | Yes. Units can mix departments, and runs with 2 or more departments earn extra points |
| Cash or points? | Both: completed runs pay cash through Renewed-Banking and earn leaderboard points |
| Where does the cash come from? | New money paid by the server by default; can be switched to the department's Renewed-Banking account |
| Does pay scale with difficulty? | Yes, through the team's tier: more participants make the mission harder and raise the cash multiplier. Star multipliers exist in Config.Difficulty but are 1.0 by default, so builders can't raise pay by picking 3 stars |
| NPC calls? | SC-NPCPolice calls never end a mission; real calls end it at once with no penalty |
| What counts as getting a real call? | Being assigned to it by a dispatcher, or marking yourself responding. Just seeing the alert does not end a mission |
| Shots fired from missions? | Suppressed through the Crimson-Arena hook that SC-Dispatch and SC-Ambulance already support; anything that slips through is cleared |
| Leaving the start route in a unit? | Only that officer's run ends (Abandoned, with the type cooldown); the rest of the unit carries on |
| Officer down? | The run is Failed for that officer, with the type cooldown. No EMS on duty: picked up automatically after 15 seconds, with no hospital bill. EMS on duty: an EMS request is sent for them |

Assumptions

- All draws, scaling, points and cash are decided server-side; the client only reports events.

- Missions are local to their participants and never spawn anything other players must interact with.

## Availability

Missions have no activation requirements: any on-duty officer in a department listed in Config.Departments (SAST and FIB today) can open Crimson-Police and start a mission at any time.

- Only the active job counts. With sc-multijob a player can hold several jobs; a police job that is not the active one gives no access.

- Going off duty or switching the active job during a run removes that officer from the run as Abandoned (type cooldown applies); the run continues for the rest of the unit.

- Officers suspended in SC-Dispatch or in Crimson-Police cannot open the Officer UI.

- Being assigned to, or responding to, a real SC-Dispatch call ends the officer's run at once with no penalty and no cooldown. SC-NPCPolice calls never end a run. While an officer is responding to a real call, the server refuses their mission accepts.

- Per-officer limits: one active run at a time, at most 8 completed runs per real-time hour, and per-mission cooldowns. Server-wide, at most 12 runs can be active at once, 4 of them Tactical.

## Interfaces

Crimson-Police has three separate interfaces, all custom standalone NUI built for this resource, and each role only sees its own. The server re-checks permissions on every action, so a hidden button is never the only protection.

| Interface | Who can open it | How it opens | Look |
|---|---|---|---|
| Officer UI | On-duty member of a department in Config.Departments | /CrimsonPolice (optional keybind or tablet item) | The officer's department theme and logo watermark |
| Supervisor UI | Officer with a grade at or above their department's supervisorGrade | "Supervisor" switch inside the Officer UI | The supervisor's department theme and logo watermark |
| Admin UI | Anyone with the ace crimsonpolice.admin, on duty or not | /CrimsonPoliceAdmin, a full-screen panel of its own, not the tablet | Neutral Crimson-Police theme, no watermark |

Every screen shows "Crimson-Police" as the app title. The Officer and Supervisor UIs also show the viewer's department name and tag, rank and callsign in the header, e.g. "San Andreas State Troopers · SAST · Sergeant · 2L-14". Rank and callsign are read live from Qbox, as SC-Police sets them.

Officer UI — seven screens on a left sidebar, with the officer's current run pinned to the top of every screen.

| Screen | Contents | Key actions |
|---|---|---|
| Home | Officer card (callsign, rank, department tag, XP level badge, streak (and whether this week's grace day is left), season points, cash earned this week), today's goal and this week's goal, Type of the Day | Open the Mission Board |
| Mission Board | One card per mission type (Patrol, Training, Investigation, Tactical): cash per officer, points, how many missions are in the pool, solo or unit, cooldown if locked, "Server busy" when the run cap is reached, "On a call" while the officer is responding to a real call. A Weekly Boss card appears Friday–Sunday. While a Cross-Department Mission is active, the board shows only that mission's card | Accept a type, join a Cross-Department Mission |
| Unit | Your unit's members (any department, with rank and callsign) and invites waiting for you | Invite officers (before the leader accepts a type), accept or decline an invite, leave the unit |
| Active Mission | Name of the drawn mission, tier (expected until the run moves to In progress), start-route status (on route, or the off-route countdown), objective checklist, timer, partners, expected cash and points | Set GPS, recalculate the route (up to 2 times per run), abandon (confirm dialog) |
| Leaderboard | Tabs Weekly · Monthly · Season · All-time; filters for mission type, unit, cross-department and department; top 25 plus your own row pinned | Tap an officer to view their public profile |
| Department Challenge | Score bar per department, weeks left, this week's bounty, your department's top 5 contributors | Tap a department to see its contributors |
| Profile & History | XP level badge, XP bar, badges, last 20 runs with points, cash and how each ended | Open a breakdown, dispute a flagged, voided or failed run from the last 48 hours |

Supervisor UI — its own layout and sidebar. Supervisors play missions from the Officer UI exactly like officers; the Supervisor UI is for oversight.

| Screen | Contents | Key actions |
|---|---|---|
| Mission List | Every mission by name, built-in and custom: type, difficulty, officers supported, current base payout, cooldowns, who is running it now. Officers never see this list | Launch a Cross-Department Mission (missions open to every department that support 2+ officers; never the Weekly Boss) |
| Cross-Department Mission | The active operation: mission, launcher, joined participants by department, tier, status | Start now, relaunch after a fail, cancel |
| Live Missions | Runs involving their department: participants, mission type, drawn mission, tier, time left | Force recall |
| Review Queue | Flagged runs with the reason (e.g. outside help), and disputes about flagged or voided runs, involving their department; their own runs never appear here | Approve, void or reject (reason required) |
| Payouts | Payout per mission type, with the allowed range; a type an admin has set shows "Set by admin" and is read-only; single-mission payouts are not shown | Change an unlocked type's payout (within range, once per 30 minutes per type) |
| Mission Builder | Their drafts plus published missions | Build, record routes, test, publish, archive; roll back or break an edit lock (as Config.Permissions allows) |
| Department Report | Challenge standing, this week's bounty, officer activity this week | Open an officer's activity |

Admin UI — a separate full-screen panel for server admins, covering every department.

| Screen | Contents | Key actions |
|---|---|---|
| Payouts | Every mission type and every mission with its base payout; admin payouts marked "Admin · permanent" | Set or clear a type or mission payout |
| Missions | All built-in and custom missions, version, Lua file path, "edited in code" flag, edit locks; built-in missions can only be turned off in config (Config.DisabledMissions) | Build, publish tested drafts, archive, restore or roll back custom missions; break an edit lock; reload mission files; launch, start now, relaunch or cancel a Cross-Department Mission |
| Seasons & Challenge | Current season, department standings, bounty history | Start or end a season, override this week's bounty |
| Leaderboards | Every board and period, cash paid per officer, and any payment left in paying after a crash | Void runs, award points |
| Officers | Search any officer: rank, callsign, history, badges, cash earned, suspensions, disputes about failed runs | Suspend, unsuspend, answer a dispute (manual award or dismiss) |
| Departments | Each department in Config.Departments: name, jobs, colours, logo thumbnail, member count, society balance (only when Config.Cash.source = 'society') | Preview a department's tablet theme (read-only) |
| Permissions | Read-only view of Config.Permissions: which supervisor actions are switched on | — |
| Audit Log | Every supervisor and admin action, filterable | Export |
| Testing | Every mission and each of its locations with its last test result (Passed, Failed, Not tested or Changed since test), the tier, who tested it and when | Start a test run (mission, location, tier, start route on or off), invite testers, record a result |

UI build: a custom standalone UI in React 18 + TypeScript, built with Vite into web/dist. Every screen, the Mission Builder, the mission HUD (objectives, timers, route warnings) and all notifications are Crimson-Police's own NUI; no ox_lib menus, context menus, input dialogs or notifications are used for them. Apart from ox_target's interaction prompts and ox_inventory's own screens, ox_lib's progress bar and skill check are the only outside UI, and only during missions. All text lives in locales/en.json. Opening the Officer UI plays a tablet prop and animation; closing it removes the prop.

## Departments & tablet theming

Each entry in Config.Departments sets that department's name on the tablet, its colours and its logo watermark. Today that is SAST and FIB; adding BCSO or any other department is a config change and a restart.

What a department entry controls

| Field | What it does |
|---|---|
| key (e.g. sast) | Internal id stored with runs and scores; never shown to players |
| label | Full department name in the tablet header, e.g. "San Andreas State Troopers" |
| short | Short tag on leaderboards, unit lists and badges, e.g. "SAST" |
| jobs | Qbox job names that belong to this department; must match sc-police and sc-dispatch |
| supervisorGrade | Job grade level (the rank's level in Qbox, as SC-Police uses it) that opens the Supervisor UI. SC-Dispatch's roster treats grade 4 as command staff |
| societyAccount | Renewed-Banking account, used only when Config.Cash.source = 'society' |
| theme | Tablet colours: primary, accent, background, surface and optional text |
| logo | Logo file or URL, and how the watermark looks |

Theme colours

| Key | Used for |
|---|---|
| primary | Header bar, primary buttons, active sidebar item, progress bars |
| accent | Highlights, badges, focus outlines, the Type of the Day tag |
| background | Tablet body behind all content |
| surface | Cards, tables and dialogs |
| text | Main text. Optional: when left out it is picked automatically (white or near-black) for contrast with background |

Colours are 6-digit hex values such as #1f4e8c. A missing or invalid colour falls back to the Crimson-Police default with a console warning.

Logo and watermark

- Put the logo in the resource's logos/ folder (PNG, WebP or SVG; a square transparent PNG of at least 1024 × 1024 works best) and set logo.file, or set logo.url to a direct https:// image link. No UI rebuild is needed; restart the resource.

- The watermark is the logo drawn once, centred behind every Officer and Supervisor UI screen: below all content, above the background, fixed in place while content scrolls, and it never blocks clicks.

- logo.opacity (0.0–0.25, default 0.08) sets how strong it is, logo.size (share of the tablet height, default 0.6) sets how large, and logo.grayscale = true draws it in greyscale.

- logo.watermark = false hides the watermark but keeps the small logo in the header.

- If the logo fails to load, the tablet shows no watermark and no broken-image icon, and the server console warns once.

Adding a department (example: BCSO)

- Make sure the job exists in Qbox (e.g. bcso). sc-police and sc-dispatch already list bcso.

- Copy the fib block in Config.Departments, rename the key to bcso, and set label, short, jobs = { 'bcso' }, supervisorGrade, societyAccount, theme and logo.

- Put bcso.png in Crimson-Police/logos/.

- Restart Crimson-Police. BCSO officers now see their own name, colours and watermark, and BCSO appears on the leaderboards, in the department challenge, in unit invites and in the Mission Builder.

## Mission types, draw & teams

Officers pick one of four mission types, and the server draws a random mission of that type, scaled to the number of participants.

| Mission type | Points (config) | Missions |
|---|---|---|
| Patrol | 60 | Beat Patrol, Business Check, Street Race Bust |
| Training | 100 | EVOC Course, Pursuit Sim, Stolen Vehicle Takedown |
| Investigation | 160 | Warrant Service, Manhunt |
| Tactical | 200 | Gang Shootout, Hostage Rescue, Bomb Disposal, Armored Truck Escort, Prison Break |

Cash per type is in Cash payouts. Custom missions join their type's pool when they are published.

Random draw rules

- The pool is every published mission of the chosen type that is open to every participant's department, supports the unit's size, is not turned off in Config.DisabledMissions, and is off cooldown for every participant.

- The draw never gives an officer or unit the mission they last completed or abandoned in that type. With 4 or more missions in the pool it also skips the last two.

- If only one mission is eligible it can repeat. If none is, the type card shows as locked with the reason, e.g. "No Patrol missions for a unit of 3".

- The location is drawn from the mission's list. A location in use by another run is reserved and skipped, and so is any spot with a non-participant player within 75 m while another spot is free.

- At most 12 runs can be active server-wide, and at most 4 of them Tactical. When the cap is reached, the affected type cards show "Server busy".

- The mission is revealed only after the type is accepted. There is no reroll: abandoning, leaving the start route, or not reaching the start within the mission's start timeout (10 minutes by default) ends the run as Abandoned and puts the whole type on cooldown.

Route to the start

When a type is accepted, each participant's tablet sets a GPS route from where they are to the mission start. That route is the only accepted way there.

- When the route is set, the client samples it every 50 m (from GTA's GPS route, e.g. GetPosAlongGpsTypeRoute) and keeps that line fixed. It is not recalculated automatically.

- Every 2 seconds the client reports how far the officer is from that line (server:routeStatus).

- More than 120 m off the line for 10 seconds shows a warning on the HUD and the tablet. Still off it 30 seconds after leaving it ends that officer's run as Abandoned (type cooldown applies). Getting back within 120 m resets the timer, and no report for 10 seconds counts as off route.

- Each participant can tap Recalculate route on the Active Mission screen up to 2 times per run, for example when a road is blocked; the new line starts from where they are.

- The server also tracks the straight-line distance to the start. If it grows more than 1,000 m past the closest the officer has been, the run is Abandoned whatever the client reports.

- The check stops when that participant reaches the start. A run moves to In progress when its first participant reaches the start; anyone still driving keeps their route check until they arrive. A real call ends the run anyway, with no penalty.

- For a mission whose start is a circle (Manhunt), the route leads to the circle's centre until the officer is inside it.

- All numbers are in Config.Route.

Units

- Build the unit first: any officer or supervisor can invite on-duty officers from any department into a unit of up to 4 on the Unit screen, and invitees accept on their own tablet. Whoever sends the first invite is the leader, and a solo officer leads themselves. If the leader leaves before accepting, the longest-standing member takes over, and a unit left with one member dissolves.

- The unit leader picks the type. Invites close at that moment, because the draw depends on the unit's size and every member's cooldowns. Every member gets the same drawn mission.

- The run's tier is set when it moves to In progress, from the members still in the unit. If the team shrinks later, the run rescales (see When someone leaves mid-run); the tier never goes up.

- A member who leaves, goes off duty or switches job mid-run is Abandoned; the run continues for the rest.

Scaling by participants

Every run is scaled when it starts, and rescaled if the team shrinks (see When someone leaves mid-run). The tier comes from the number of participants and sets enemy numbers, enemy strength, points and cash.

| Participants | Tier | Counts marked "scales" in a mission card | Armed NPC accuracy / armour | Points team multiplier | Cash multiplier |
|---|---|---|---|---|---|
| 1 | Standard | × 1.0 | base | × 1.00 | × 1.00 |
| 2 | Reinforced | × 1.25 | +5 / +10 | × 1.10 | × 1.15 |
| 3–4 | Heavy | × 1.5 | +10 / +25 | × 1.15 | × 1.30 |
| 5–6 | Major | × 2.0 | +15 / +50 | × 1.20 | × 1.50 |
| 7–8 | Critical | × 2.5 | +20 / +75 | × 1.25 | × 1.75 |

- Scaled counts are rounded to the nearest whole number, halves up.

- Major and Critical are only reachable in a Cross-Department Mission (up to 8 participants); normal units stop at 4.

- Caps, counted at any one moment: at most 25 armed NPCs alive and 80 spawned entities per run. Dead NPCs and wrecked vehicles are deleted 30 seconds after they die, and the next wave waits until there is room; scaled counts are never cut to fit the caps; they only change when the team shrinks (see When someone leaves mid-run).

- Cross-department bonus: a run whose participants come from 2 or more departments earns × 1.10 points on top of the team multiplier.

When someone leaves mid-run

If a participant leaves a run that is In progress, for any reason, the run rescales for the team that's left:

- Waves, vehicles and NPCs not yet spawned use the tier for the new team size: its counts, accuracy and armour. NPCs already spawned stay as they are.

- A wave that has partly spawned gets the new scaled total, and only the NPCs still missing are spawned (none if it already has that many).

- The points and cash tier drops only when the leave could be used to boost the run:

| Why they left (end_reason) | NPCs not yet spawned | Points and cash tier |
|---|---|---|
| Real call, force recall or went down (real_call, force_recall, downed) | Shrink to the team that's left | Stays as it was; if the leave later becomes real_call_cancelled, it drops then |
| Quit, off duty, job change, suspended, disconnected, or removed by the idle check (quit, off_duty, job_change, suspended, disconnected, idle) | Shrink to the team that's left | Drops to the team that's left |

- The tier never goes up during a run, and nobody can join after it starts. The HUD shows the new tier, and the result screen shows the tier used for points and cash.

- Both behaviours are set in Config.Rescale.

Cross-Department Missions

A supervisor or admin can launch one specific mission for every department at once. Until it is completed or cancelled, it is the only mission anyone can start.

- Launch: Supervisor UI → Mission List (or Admin UI → Missions) → pick a mission that is open to every department (empty departments) and supports 2 or more officers → Launch. The Weekly Boss cannot be launched. Only one Cross-Department Mission can be active server-wide, and a new one can be launched at most every 30 minutes (Config.CrossDept.cooldown).

- Board lock: every on-duty officer in every department gets a tablet notification, and their Mission Board shows only this mission's card. The server refuses every other new mission, including the Weekly Boss. Runs already accepted or in progress finish normally.

- Join: officers and supervisors from any department tap Join, up to 8 participants. Joining closes when the launcher taps Start now, or 5 minutes after launch. At least 2 participants are needed to start.

- Run: participants get a start route (the route rules apply), and the run moves to In progress when the first participant reaches the start; the tier is set then, from everyone still on the run. Points, scaling and cash work like any run, and the cross-department bonus applies when 2 or more departments joined.

- End: the lock lifts when the run is Completed. If it Fails or every participant leaves, the operation stays active: any supervisor can relaunch it (a new join window) or cancel it. It auto-cancels after 30 minutes with no run in progress.

- Exempt rules: Cross-Department Missions ignore type and per-mission cooldowns, the no-repeat rule, the hourly cap and the server run cap, and never roll a modifier.

## Mission catalog

v1 ships 13 missions plus the Weekly Boss, one file each in missions/builtin/. This table is the summary; each mission's full behaviour is in Mission cards.

| Mission | Id and file name | Type | Officers | Difficulty | Time limit | What scales |
|---|---|---|---|---|---|---|
| Beat Patrol | beat_patrol | Patrol | 1 | ★ | 8 min | — |
| Business Check | business_check | Patrol | 1 | ★ | 10 min | — |
| Street Race Bust | street_race_bust | Patrol | 1–2 | ★★ | 4 min (the race) | Racers |
| EVOC Course | evoc_course | Training | 1 | ★★ | 4 min | — |
| Pursuit Sim | pursuit_sim | Training | 1 | ★★★ | 5 min | — |
| Stolen Vehicle Takedown | stolen_vehicle_takedown | Training | 1–2 | ★★★ | 8 min | Suspects in the car (max 4) |
| Warrant Service | warrant_service | Investigation | 2–4 | ★★★ | 12 min | Armed associates |
| Manhunt | manhunt | Investigation | 1–4 | ★★ | 12 min | Fugitives |
| Gang Shootout | gang_shootout | Tactical | 1–4 | ★★★ | 10 min | Hostiles |
| Hostage Rescue | hostage_rescue | Tactical | 1–4 | ★★★ | 10 min | Hostiles |
| Bomb Disposal | bomb_disposal | Tactical | 1–4 | ★★ | 6 min (the device timer) | Devices |
| Armored Truck Escort | armored_truck_escort | Tactical | 2–4 | ★★★ | 12 min | Ambush waves and cars |
| Prison Break | prison_break | Tactical | 1–4 | ★★★ | 10 min | Inmates |
| Weekly Boss: Kingpin | weekly_boss_kingpin | Tactical (event card) | 1–4 | ★★★ | 15 min | Hostiles |

The officer counts are for normal runs. As a Cross-Department Mission, any mission that supports 2 or more officers takes up to 8.

Mission definition fields: id, label, description (shown on the Active Mission screen after the draw), type, departments (empty = every department), minOfficers, maxOfficers, difficulty (1–3), timeLimit (seconds after the run moves to In progress), startTimeout (seconds to reach the start; default Config.Limits.startTimeout), cooldown (per officer, seconds), locations, objectives (blocks, in order; each may set minSeconds, its minimum believable time, and presenceRange; otherwise the block's defaults apply), scaling (which counts scale), items (optional ox_inventory items given at the start and removed at the end), bonuses, penalties, vehiclePenalties (default true; false turns off the heavy vehicle-damage penalty where contact or gunfire damage is expected). There is no payout field and no grade requirement. Every mission file, built-in or custom, contains exactly one RegisterMission({ ... }) call (see Example files).

Design rules

- NPCs only; nothing a non-participant can take or interact with. NPCs never drop weapons or loot when they die (SetPedDropsWeaponsWhenDead(ped, false)), and ox_target options only appear for participants.

- Mission NPCs and vehicles are networked entities created by the server (OneSync), so every participant sees the same ones. The run host's client runs their AI, and the server deletes everything when the run ends for any reason, even if no participant is left.

- From the moment a participant reaches the mission start they carry the alert-suppression flag, so their mission combat creates no SC-Dispatch or SC-Ambulance alerts (see Real calls, alerts & downed officers).

- Built-in missions ship with at least 5 locations (3 for Armored Truck Escort routes, EVOC layouts and Kingpin compounds). Custom missions need at least 3 (Config.Builder.minLocations).

- NPC arrests use Crimson-Police's own ox_target "Cuff suspect" action. They never call sc-police's player cuffing or jail.

## Mission cards

Each card is the full behaviour of one mission. Every card also gets the common bonuses and penalties in Scoring unless it says otherwise, and every count marked "scales" is multiplied by the run's tier.

### Beat Patrol · beat_patrol

- Basics: Patrol · 1 officer · ★ · time limit 8 min · cooldown 10 min

- Locations: 6+ districts, each with 8+ checkpoint spots; a run uses one district and 5 random spots

- Start: the first checkpoint

- Spawns: none; markers and blips only

- Objectives: 1) drive to each checkpoint in order; 2) stop inside its 10 m marker in a police vehicle for 10 seconds

- Scales: nothing (solo)

- Fail if: the time limit runs out

- Bonuses and penalties: common only

- Cleanup: markers and blips

### Business Check · business_check

- Basics: Patrol · 1 officer · ★ · time limit 10 min · cooldown 10 min

- Locations: 12+ businesses; a run uses 4 random ones

- Start: the first business

- Spawns: none; ox_target zones on the front doors

- Objectives: 1) at each business, ox_target "Check door" on the front door (5 s progress); 2) the server has rolled each door as secure (75%) or open (25%) and shows the result; an open door adds "Secure door" (5 s progress); 3) log the result on the tablet: "Secure" or "Found open – secured"

- Scales: nothing (solo)

- Fail if: the time limit runs out

- Bonuses: each correctly logged result +5

- Penalties: each wrongly logged result −5

- Cleanup: target zones and blips

### Street Race Bust · street_race_bust

- Basics: Patrol · 1–2 officers · ★★ · time limit 4 min (the race) · cooldown 15 min

- Locations: 5+ looped race routes of 2–3 km, recorded as road routes (see Route recording)

- Start: an intercept point on the route (waypoint set on accept); the race starts when the first participant arrives

- Spawns: 3 NPC racers in sports cars (scales), racing the route until the time limit ends

- Objectives: 1) stop racers before the race ends; a racer is stopped when its car stays below 5 km/h for 5 seconds; 2) detain each stopped driver with ox_target "Detain driver" (3 s progress). The run is Completed when every racer is detained, or when the time limit ends with at least one detained

- Scales: racers (base 3)

- Fail if: the time limit ends with no racer detained

- Bonuses: +30 per racer detained, plus +20 more if every racer is detained

- Penalties: ramming a racer at over 100 km/h −10 each; no heavy-damage penalty, since boxing racers in means contact (vehiclePenalties = false)

- Cleanup: racers, their cars and blips

### EVOC Course · evoc_course

- Basics: Training · 1 officer · ★★ · time limit 4 min · cooldown 10 min

- Locations: 3+ course layouts in open areas such as airfields; each has 12–20 checkpoints and Gold / Silver / Bronze medal times

- Start: the course start marker; the timer starts at the first checkpoint

- Spawns: checkpoint markers only (no cones or props)

- Objectives: drive through every checkpoint in order in a police vehicle; a missed checkpoint must be driven through before the next one counts; each wall or vehicle contact adds 2 seconds

- Scales: nothing (solo)

- Fail if: the time limit runs out, or the vehicle becomes undriveable

- Bonuses: Gold medal +50, Silver +25, Bronze +10 (replaces the common time bonus); no contact at all +10

- Penalties: common only

- Cleanup: markers

### Pursuit Sim · pursuit_sim

- Basics: Training · 1 officer · ★★★ · time limit 5 min · cooldown 15 min

- Locations: 5+ start points, each with a flee route

- Start: the start point; the getaway car spawns 50 m ahead and flees when the officer arrives

- Spawns: 1 getaway car with 1 driver, who flees but never shoots

- Objectives: stay within 150 m of the car for a total of 3 minutes

- Scales: nothing (solo)

- Fail if: the officer is more than 250 m from the car for 10 seconds straight, the officer's vehicle becomes undriveable, or the time limit runs out

- Bonuses: medal by average distance: Gold under 40 m +50, Silver under 80 m +25, Bronze under 150 m +10 (replaces the common time bonus)

- Penalties: ramming the getaway car −10 each (this is a follow exercise)

- Cleanup: car and driver

### Stolen Vehicle Takedown · stolen_vehicle_takedown

- Basics: Training · 1–2 officers · ★★★ · time limit 8 min · cooldown 15 min

- Locations: 5+ last-seen areas, each with a flee route

- Start: within 60 m of the stolen car; it flees as soon as a participant with lights on is that close

- Spawns: 1 stolen car with 2 suspects (scales, max 4); after the stop, each suspect has a 20% chance to flee on foot

- Objectives: 1) stop the car with a PIT or box-in (below 5 km/h for 5 seconds); 2) aim at each suspect until they surrender (hands up, then kneel); 3) cuff each suspect with ox_target "Cuff suspect" (5 s progress), catching any who flee first

- Scales: suspects in the car (base 2, max 4)

- Fail if: a suspect escapes (more than 400 m from every participant for 20 seconds), or the time limit runs out

- Bonuses: car stopped within 2 minutes of the start +15

- Penalties: ramming at over 100 km/h −10 each; no heavy-damage penalty, since PIT stops and box-ins mean contact (vehiclePenalties = false)

- Cleanup: car and suspects

### Warrant Service · warrant_service

- Basics: Investigation · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min

- Locations: 5+ houses, each with a front door and a yard

- Start: within 50 m of the house

- Spawns: the suspect inside, plus 1 armed associate (scales)

- Objectives: 1) ox_target "Knock and announce" on the front door; 2) the suspect's response is rolled: surrenders at the door (50%), flees out the back on foot (30%) or fights with a pistol (20%); associates always fight; 3) cuff the suspect ("Cuff suspect", 5 s progress) unless the suspect was killed while fighting; 4) neutralise every associate (killed, or surrendered and cuffed); 5) ox_target "Search the property" at the yard marker (8 s progress)

- Scales: armed associates (base 1)

- Fail if: the suspect escapes (more than 400 m from every participant for 20 seconds), every participant is downed, or the time limit runs out

- Bonuses: suspect taken alive +15; no participant downed +10% of type points

- Penalties: common only, except the heavy vehicle-damage penalty, which is off because vehicles take gunfire (vehiclePenalties = false)

- Cleanup: NPCs, target zones and blips

### Manhunt · manhunt

- Basics: Investigation · 1–4 officers · ★★ · time limit 12 min · cooldown 20 min

- Locations: 5+ search regions, each with 6+ clue spots and 6+ hiding spots

- Start: entering the 600 m search circle, shown on the map when the type is accepted

- Spawns: 1 fugitive (scales) hidden inside the circle; 3 clue props (a dropped bag, a phone, a witness NPC)

- Objectives: 1) check each clue with ox_target (4 s progress); each clue shrinks the circle 600 → 300 → 150 → 50 m, always still containing a fugitive; 2) when a participant gets within 30 m, that fugitive runs on foot; 3) catch and cuff every fugitive ("Cuff suspect", 5 s progress). Fugitives are unarmed and give up when stunned, or when a participant stays within 3 m of them for 3 seconds

- Scales: fugitives (base 1)

- Fail if: a fugitive escapes (more than 300 m from every participant for 30 seconds after running), or the time limit runs out

- Bonuses: all 3 clues checked before the first arrest +10; no weapons fired +10

- Penalties: common only (killing an unarmed fugitive fails the mission)

- Cleanup: props, NPCs and search-circle blips

### Gang Shootout · gang_shootout

- Basics: Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min

- Locations: 5+ remote hideouts away from civilian hotspots, each with 12+ hostile spawn points

- Start: within 80 m of the hideout

- Spawns: 20 hostiles (scales) in 3 waves of 7 / 7 / 6, each wave scaled the same way; the next wave spawns when 2 or fewer of the current wave are alive, or after 90 seconds. Pistols and SMGs; base accuracy 25 and armour 0, plus the tier's increase

- Objectives: 1) neutralise every hostile (killed, or surrendered and cuffed; a hostile under 25% health has a 30% chance to surrender); 2) ox_target "Secure the scene" at the scene marker (8 s progress)

- Scales: hostiles

- Rules: hostiles use their own relationship group, hostile only to participants; NPC traffic is blocked within 120 m while the run is active

- Fail if: every participant is downed, or the time limit runs out

- Bonuses: no participant downed +10% of type points; each hostile arrested +5

- Penalties: common only, except the heavy vehicle-damage penalty, which is off because vehicles take gunfire (vehiclePenalties = false)

- Cleanup: peds, vehicles and blips; NPC traffic restored

### Hostage Rescue · hostage_rescue

- Basics: Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min

- Locations: 5+ enterable base-game stores or banks (e.g. 24/7 stores, Fleeca banks)

- Start: within 60 m of the building

- Spawns: 4 armed hostiles (scales) inside; 3 hostages kneeling with their hands tied

- Objectives: 1) neutralise every hostile; 2) free each hostage with ox_target "Cut restraints" (6 s progress); 3) each freed hostage walks to the safe marker outside. Completed when every hostage is there

- Scales: hostiles (hostages stay at 3)

- Fail if: a hostage dies, every participant is downed, or the time limit runs out

- Bonuses: no hostage hurt +15; no participant downed +10% of type points

- Penalties: a hostage hit by participant fire −50 each; no heavy vehicle-damage penalty, because vehicles take gunfire (vehiclePenalties = false)

- Cleanup: peds and blips

### Bomb Disposal · bomb_disposal

- Basics: Tactical · 1–4 officers · ★★ · time limit 6 min (the device timer) · cooldown 20 min

- Locations: 5+ buildings, each with 6+ hiding spots

- Start: within 50 m of the building; the time limit, which is the device timer, starts now

- Spawns: 1 device prop (scales), each at a different random hiding spot

- Objectives: 1) search hiding spots with ox_target "Search" (3 s progress) until every device is found; 2) defuse each device with 4 ox_lib skill checks (easy, medium, medium, hard). All devices share the one timer: a miss takes 30 seconds off it, and 2 misses in a row on one device sets that device off

- Scales: devices (base 1)

- Fail if: the timer reaches 0, or a device goes off. The explosion is an effect only (damage scale 0) and hurts nobody

- Bonuses: no missed skill checks +15; every device found within 2 minutes of the start +10

- Penalties: common only

- Cleanup: device props, target zones and blips

### Armored Truck Escort · armored_truck_escort

- Basics: Tactical · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min

- Locations: 3+ road routes recorded by driving them (see Route recording), each with a depot, a destination and 5+ ambush points

- Start: the depot; the truck leaves when the first participant arrives

- Spawns: an armored truck (stockade) with an NPC driver that follows the route's roads at its set speed (default 60 km/h), keeping to its lanes; 2 ambush waves (scales) of 2 cars each (scales), with 2 armed attackers per car, triggered at random ambush points along the route

- Objectives: 1) escort the truck to the destination; 2) neutralise each ambush wave; 3) the truck reaches the destination with no attacker within 100 m

- Scales: ambush waves and cars per wave

- Fail if: the truck is destroyed, the truck is stopped for 60 seconds straight, every participant is downed, or the time limit runs out

- Bonuses: truck arrives above 50% health +10% of type points; no participant downed +10% of type points

- Penalties: common only, except the heavy vehicle-damage penalty, which is off because ramming ambush cars is expected (vehiclePenalties = false)

- Cleanup: truck, attackers, their cars and blips

### Prison Break · prison_break

- Basics: Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min

- Locations: 5+ breakout points on the outer perimeter of Bolingbroke Penitentiary, each with escape routes

- Start: within 150 m of the breakout point

- Spawns: 5 inmates (scales) in prison clothes, already outside the fence and scattering on foot along the escape routes; 2 in every 5 carry pistols and fire when a participant is within 15 m

- Objectives: catch every inmate, then cuff them ("Cuff suspect", 5 s progress). An unarmed inmate gives up when a participant aims at them within 10 m, when stunned, or when a participant stays within 3 m for 3 seconds. An armed inmate gives up only when stunned or below 50% health

- Scales: inmates

- Rules: nothing spawns inside the prison walls, where real players may be jailed

- Fail if: an inmate escapes (more than 600 m from every participant for 30 seconds), or the time limit runs out

- Bonuses: +10 per inmate arrested alive

- Penalties: common only, except the heavy vehicle-damage penalty, which is off because vehicles take gunfire (vehiclePenalties = false)

- Cleanup: inmates and blips

### Weekly Boss: Kingpin · weekly_boss_kingpin

- Basics: Tactical event card · 1–4 officers · ★★★ · time limit 15 min · once per officer per week, Friday–Sunday (server time); cannot be launched as a Cross-Department Mission

- Locations: 3+ compounds, each with 16+ hostile spawn points

- Start: within 100 m of the compound

- Spawns: 30 hostiles (scales) in 4 waves of 8 / 8 / 7 / 7, each scaled the same way, then the Kingpin after the last wave. Pistols, SMGs and shotguns; base accuracy 30 and armour 25, plus the tier's increase. The Kingpin has armour 100, health 400 and an assault rifle, and does not scale

- Objectives: 1) neutralise every hostile; 2) neutralise the Kingpin; 3) ox_target "Secure the scene" (8 s progress)

- Scales: hostiles

- Fail if: every participant is downed, or the time limit runs out

- Points and cash: 500 points (Config.Events.weeklyBoss.points) instead of the type points; base payout Config.Events.weeklyBoss.payout ($2,500) until an admin sets a mission payout; counts as Tactical for the leaderboards, the 4-Tactical run cap and the hourly cap, never rolls a modifier, and is accepted from its card with the key weekly_boss. Its runs are stored with mission_type = 'tactical'. Abandoning it (except for a real call, force recall or cancel) uses up that week's attempt and puts no type on cooldown

- Bonuses: Kingpin arrested alive +50; no participant downed +10% of points

- Penalties: common only, except the heavy vehicle-damage penalty, which is off because vehicles take gunfire (vehiclePenalties = false)

- Cleanup: as Gang Shootout

## Special events

Three events rotate on top of the normal missions to keep the board fresh.

| Event | How it works | Limits |
|---|---|---|
| Type of the Day | One mission type, picked at the daily reset (Config.Time.resetHour, server time) with a random seed made from the date, so a restart keeps the same type, earns double points (applied after the 2× points cap) | Points only; cash is not doubled |
| Modifiers | 25% of runs roll one modifier: Armored Hostiles (Tactical only: +50 armour on armed NPCs), Time Crunch (time limit cut by 25%) or Radio Silence (after the start, no blips for mission NPCs or objectives, and the Active Mission screen shows only street and zone names; the start route still shows) | +25% of P and × 1.25 cash; one modifier per run; never on Cross-Department Missions |
| Weekly Boss | The Kingpin mission (see Mission cards) on its own Mission Board card, Friday–Sunday | Once per officer per week; hidden while a Cross-Department Mission is active; cannot be launched as one |

## Mission lifecycle

Every run follows one server-owned state machine; the client never changes state on its own.

run lifecycle · Available to Completed, Failed or Abandoned

Accepting a mission type draws the mission and moves the run to Accepted. Each participant must then follow the start route and reach the start within the mission's start timeout (10 minutes by default), or their run ends as Abandoned. From Accepted or In progress an officer can Abandon: no points, no cash, and a 5-minute cooldown on the whole mission type. A real call or a supervisor's force recall ends the run at once with no penalty and no cooldown. Going down ends it as Failed. In a unit, one member leaving does not end the run for the others; it rescales for the team that's left (see When someone leaves mid-run).

| State | Timer | Points | Cash | Cleanup |
|---|---|---|---|---|
| Available | — | — | — | Not a run yet: the mission type card on the board |
| Accepted | Start timeout (10 min by default) | 0 | $0 | Waypoint removed if abandoned |
| In progress | Mission timeLimit | Earned per objective, held until the end | Held until the end | — |
| Completed | — | Full points (see Scoring) | Paid to each participant (see Cash payouts) | The server deletes everything |
| Failed | — | 25% of type points × share of objectives done | $0 | The server deletes everything |
| Abandoned | — | 0 | $0 | The server deletes everything once no participant is left |

Results are per participant, and each run row records how it ended (end_reason). A participant who leaves early gets their own result and loses their mission items, while the run continues for everyone left:

| How it ended | end_reason | Result | Type cooldown |
|---|---|---|---|
| Tapped Abandon, left the start route, missed the start timeout, never reached the start (idle check), switched job, went off duty or was suspended | quit, off_route, start_timeout, idle, job_change, off_duty, suspended | Abandoned | Yes |
| Un-marked responding within 60 seconds of a real call | real_call_cancelled | Abandoned | Yes |
| Real call, a supervisor's force recall, or the Cross-Department Mission was cancelled | real_call, force_recall, cancelled | Abandoned | No |
| Went down | downed | Failed (partial points, no cash) | Yes, so going down can't be used to reroll |
| Disconnected | disconnected | Failed (partial points, no cash) | Yes, so disconnecting can't be used to reroll |
| Still in the run when it ended | completed, time_limit, mission_failed | Completed or Failed | No |

The run's own end state (Completed or Failed) applies to everyone still in it. Every result except real_call, force_recall and cancelled starts that officer's cooldown for the drawn mission (its cooldown). If the resource stops mid-run, every mission entity and alert flag is removed, and active runs are dropped with no row, no points, no cash and no cooldown.

## Real calls, alerts & downed officers

Real police work always wins over a mission, mission combat never creates real calls, and a downed officer always gets help.

Real calls end missions; NPC calls never do

- Crimson-Police listens, read-only, to SC-Dispatch's responding event, which SC-Dispatch also sends when a dispatcher assigns an officer to a call. The call id shows where a call came from: ids starting with npccall- are SC-NPCPolice calls, and every other call is real.

- The server only counts a call that exists and is active in SC-Dispatch's mdt_dispatch table (a read-only lookup, see Appendix), so a faked responding event does nothing.

- When a participant marks themselves responding to, or is assigned by a dispatcher to, a real call, their run ends at once as Abandoned with no penalty and no cooldown (end_reason = 'real_call'), and the HUD shows "Mission ended — you're on a real call". The run continues for anyone left.

- If they un-mark responding within 60 seconds, that free abandon becomes a normal one: the type cooldown applies and the run's end_reason becomes real_call_cancelled, so real calls can't be used to dodge a failing mission.

- While an officer is responding to a real call, they can't accept a mission: their Mission Board shows "On a call" until the call clears, or until 20 minutes pass with no update from SC-Dispatch.

- NPC calls never end a run, and responding to one does not make an abandon free.

- Calls raised about a participant of the same run (their person-down, dead, EMS-help or panic calls, whose ids are one of Config.Calls.ownRunCallPrefixes followed by that participant's server id and an underscore, e.g. playerdown_12_…) do not count as real calls for their partners.

- All values are in Config.Calls.

No mission combat alerts

- When a participant reaches the start of their run (which is then In progress), the server sets their player state bag crimsonArena = { active = true, source = 'crimson-police' }. SC-Dispatch (Config.Integrations.CrimsonArena, already true) and SC-Ambulance (Config.ArenaIntegration.Enabled, already true) both skip shots-fired and person-down or dead alerts for players with that flag, so no edits to either resource are needed.

- The flag is removed when that participant's run ends for any reason (a downed participant keeps it until their pick-up is complete, or until just before their EMS request is sent), and from everyone when the resource stops; a Crimson-Police flag left over from a crash is removed when the resource starts. Crimson-Police only ever removes a flag it set itself.

- Backstop: Crimson-Police also listens to sc-dispatch:server:ShotsFired. If one still arrives from an In-progress participant within 300 m of their mission, it waits 1 second and clears the call with exports['sc-dispatch']:ClearNotification('shots_<src>_<time>', { 'police' }), trying the current and the previous second. It does the same for sc-dispatch:server:PlayerDown and sc-dispatch:server:PlayerDead from a participant who still carries the flag, clearing playerdown_<src>_<time> or playerdead_<src>_<time> with { 'police', 'ambulance' }. The radius and wait are in Config.Alerts.

- Note: outside missions, SC-Dispatch only exempts on-duty police, bcso and fib from shots-fired calls, so SAST officers who shoot elsewhere still create them. That is SC-Dispatch's own behaviour and the Crimson-Police build does not change it; the server owner can (see Server owner checklist).

Downed participants

- The server checks each participant's metadata.isdead and metadata.inlaststand every 2 seconds. Going down ends that participant's run as Failed. The run continues for the rest; if every participant is downed, the run is Failed.

- No EMS on duty (exports['sc-ambulance']:GetDoctorCount() returns 0): after 15 seconds the screen fades with "Picked up by an NPC unit". The server revives the officer with SC-Ambulance's own revive event (TriggerClientEvent('hospital:client:Revive', src)) and moves them to the nearest drop-off point (by default, SC-Ambulance's Pillbox and Paleto check-in points). There is no hospital bill.

- EMS on duty: the officer stays down and follows SC-Ambulance's normal flow. Crimson-Police removes their alert-suppression flag, then sends SC-Ambulance's standard EMS request for them from their client (hospital:server:EMSDownAlert, the same request as pressing G), so EMS is called.

- Crimson-Police never triggers hospital:server:RevivePlayer: SC-Ambulance permanently bans any sender who is not EMS or carrying first aid.

- All numbers are in Config.Downed.

## Scoring, points & XP levels

The server works out points from the mission type's points in config, adjusted by performance and team, and caps them at 2× the type points so no single run dominates the board.

\text{Points} = \max\left(0,\ \min\left(2P,\ \left(P + \text{Bonuses} - \text{Penalties}\right) \cdot M_{\text{team}} \cdot M_{\text{cross}} \cdot M_{\text{streak}}\right)\right)

- P: the mission type's points in Config.MissionTypes × the mission's star multiplier (Config.Difficulty.pointsByStars, 1.0 for every star by default). The Weekly Boss uses Config.Events.weeklyBoss.points. Wherever a mission card, setting or comment says "type points", it means P.

- Bonuses and penalties: the mission card's bonuses and penalties are shared by every participant; vehicle damage, pedestrian hits, lights and siren, shooting a surrendered NPC and the first-run bonus are personal to each officer.

- M_team: the points team multiplier from the tier table (× 1.00 solo up to × 1.25 at Critical), using the run's points and cash tier (see When someone leaves mid-run).

- M_cross: × 1.10 when the participants come from 2 or more departments, otherwise × 1.00.

- M_streak: personal; +5% for each consecutive day with a completed run, up to +25%, reset after a missed day, except that up to Config.Scoring.streakGraceDays missed days a week (1 by default, counted from the weekly reset) are forgiven: the streak carries on, but a forgiven day adds nothing.

- Points are worked out separately for each participant with this formula and rounded down to a whole number, never below 0. Type of the Day doubles the result after the cap. A Failed result earns 25% of P × the share of objectives completed; an Abandoned result earns 0.

- Manual awards and goal rewards are stored as their own rows in cp_mission_runs (mission_type = 'manual_award' or 'goal') and count only toward the Overall and Department boards. These rows use state = 'completed', the same word as their end_reason, and the goal id or 'manual_award' as mission_id, and they never count as runs (completed-run counts, goals, streaks, badges, the hourly cap, bounties and the 3-run minimum).

Common bonuses and penalties (apply to every mission unless its card says otherwise; the modifier bonus is Config.Events.modifierPoints and the other values live in Config.Scoring.common)

| Bonus or penalty | Value |
|---|---|
| Finished within 75% of the time limit | +20% of P (not EVOC Course or Pursuit Sim, which use medals) |
| No damage to the officer's vehicle (engine and body above 950) | +10, personal |
| First completed run since going on duty | +15, personal |
| The run rolled a modifier | +25% of P |
| Heavy damage to the officer's vehicle (body below 500; not in missions with vehiclePenalties = false) | −25, personal |
| NPC pedestrian hit by the officer's vehicle | −30 each, personal |
| Lights and siren used during Beat Patrol or Business Check | −10, personal |
| Shooting a surrendered NPC | −20 each, personal |
| Killing a surrendered or unarmed suspect, fugitive, inmate or hostage | Mission failed for everyone |

Vehicle damage where contact is expected: a mission can set vehiclePenalties = false to turn off the heavy-damage penalty, because contact or gunfire damage is part of the job there. The no-damage bonus can still be earned, and a card's own ramming penalties still apply. Built-in missions with it off: Street Race Bust and Stolen Vehicle Takedown (boxing in and PIT stops), Armored Truck Escort (ramming ambush cars), and Warrant Service, Gang Shootout, Hostage Rescue, Prison Break and Weekly Boss: Kingpin (vehicles take gunfire).

XP & XP levels: XP equals lifetime points and never resets. A run's points are added to XP when they count (a flagged run's only once it is approved) and taken away if the run is voided. XP levels come from Config.XPLevels; they are cosmetic badges on the tablet only and never change anyone's rank (their Qbox job grade).

| XP level | XP needed | Badge |
|---|---|---|
| Probationary | 0 | Grey |
| Patrol Officer | 1,000 | Bronze |
| Senior Patrol | 5,000 | Silver |
| Veteran | 15,000 | Gold |
| Elite | 40,000 | Platinum |

Achievement badges: Iron Wheels (20 completed runs with no vehicle damage), Sharpshooter (10 Gang Shootouts with no participant downed), Road Warrior (100 Patrol missions), Partner in Crime (50 unit runs), Joint Task Force (10 runs with 2 or more departments). The counts are in Config.Badges.

Daily and weekly goals: each officer gets one daily goal (picked at the daily reset, Config.Time.resetHour) and one weekly goal (picked on Monday) from Config.Goals, e.g. "Complete 2 Patrol missions" or "Complete 1 cross-department run". Progress is counted from the officer's runs since the goal was picked. Goals are picked with a random seed made from the date (or the week's start) and the officer's citizenid, so a restart keeps the same goals and nothing needs storing. Finishing one adds +50 (daily) or +200 (weekly) points once, as a 'goal' row.

## Cash payouts

Every participant in a Completed run is paid cash: the mission's base payout multiplied by how difficult the run was.

\text{Cash per participant} = \operatorname{round}\left(B \cdot M_{\text{tier}} \cdot M_{\text{mod}}\right)

- B: the base payout. If an admin has set a payout for the mission, B is that amount. Otherwise B is the mission type's payout × the mission's star multiplier (Config.Difficulty.cashByStars, 1.0 for every star by default). The Weekly Boss uses Config.Events.weeklyBoss.payout unless an admin has set one.

- M_tier: the cash multiplier from the tier table (× 1.00 at Standard up to × 1.75 at Critical).

- M_mod: × 1.25 when the run rolled a modifier, otherwise × 1.00.

- Only Completed results pay, rounded to the nearest dollar. Failed and Abandoned results pay $0. Type of the Day, streaks and bonuses change points only.

- B is locked when the type is accepted, and M_tier is set when the run starts and can only go down (see When someone leaves mid-run), so a payout change never affects a run already underway.

Default base payouts (placeholders; tune them to your economy)

| Mission type | Default type payout |
|---|---|
| Patrol | $250 |
| Training | $350 |
| Investigation | $600 |
| Tactical | $800 |
| Weekly Boss (a mission payout) | $2,500 |

Example: a Heavy-tier Gang Shootout (4 officers) with no admin payout and no modifier pays each officer $800 × 1.30 = $1,040.

Who can change payouts

| Who | Can change | Where |
|---|---|---|
| Supervisors | A mission type's payout, unless an admin has set it | Supervisor UI → Payouts |
| Admins | Any mission type's payout and any single mission's payout; both become permanent | Admin UI → Payouts, or /CrimsonPoliceAdmin payout … |

- Admin payouts are permanent: they stay until an admin changes or clears them, and survive restarts, season resets, Mission Builder re-publishes and reloads.

- When an admin sets a type's payout, that type is locked: supervisors see "Set by admin" and cannot change it.

- Supervisor limits: a supervisor can set a type's payout only between 50% and 200% of its config default (Config.Payouts.supervisorRange), at most once every 30 minutes per type (Config.Payouts.supervisorCooldown), and must give a reason. Admins are bound only by the overall range.

- A mission with an admin payout ignores later changes to its type's payout.

- Clearing (admin only) deletes the stored value: a mission goes back to its type's payout, and a type goes back to its config payout and is unlocked for supervisors.

- Overall base payout range: $0–$25,000 (Config.Cash.minPayout and maxPayout). There is one set of payouts for every department.

- The Mission Board shows the cash per officer as a range for the unit's size, for example "$1,040–$1,300" for a unit of 4 on Tactical, covering modifiers and any admin payouts in the pool.

- Every change is written to the audit log (old value, new value, who, reason) and posted to the audit webhook.

How cash is paid (by the server, once per participant per run)

- Claim the row before any money moves: UPDATE cp_mission_runs SET cash_status = 'paying' WHERE id = ? AND cash_status IN ('none','held','pending'). If no row changes, stop: it is already being paid or finished. paid, capped, unfunded and forfeited are final and are never paid again.

- Work out the amount with the formula above. If it would take the officer over Config.Cash.dailyCap for the day, pay only up to the cap (0 = no cap).

- If Config.Cash.source = 'society', withdraw the amount from the department's Renewed-Banking account with removeAccountMoney. If that returns false, pay $0, set the final status unfunded and notify the officer and online supervisors.

- Add the money with Qbox: player.Functions.AddMoney(Config.Cash.account, amount, 'crimson-police-mission'). account is 'bank' by default.

- For bank payments, record the deposit in Renewed-Banking: handleTransaction(citizenid, 'Crimson-Police', amount, 'Mission payout: <mission label>', '<department label>', '<character name>', 'deposit', 'CP-<run_uuid>-<citizenid>'). With the society source, also record a 'withdraw' on the department's account.

- Write cash_paid and the final status: capped if the cap cut the amount, otherwise paid. A row still in paying after a crash is never retried automatically; it is listed in Admin UI → Leaderboards for a manual check against the Renewed-Banking history (transaction id CP-<run_uuid>-<citizenid>).

A flagged run's cash is held until a supervisor approves it. If the officer is offline at that moment, the payment waits (cash_status = 'pending') and is made the next time they load in. A voided run's held cash stays held until its 48-hour dispute window closes or a dispute about it is rejected, and is then forfeited (cash_status = 'forfeited'). Voiding an already-paid run does not take the money back.

## Leaderboards

Four time-boxed boards rank officers by points earned in each period. Cash is never shown on public boards.

| Board | Window | Resets | Recognition (suggested) |
|---|---|---|---|
| Weekly | Monday to Sunday, starting at the reset hour (Config.Time.resetHour, 00:00 server time by default) | Every Monday | Top 3 posted to Discord and announced on the Home screen; "Officer of the Week" badge |
| Monthly | Calendar month | 1st of the month | Top 3 announced on the Home screen |
| Season | From the season's start to its end (an admin starts and ends it; 8 weeks suggested) | When an admin starts the next season | Season title and badge for the top 10 |
| All-time | Lifetime XP (Overall filter only) | Never | Display only |

Filters: Overall · Patrol · Training · Investigation · Tactical · Unit (points from runs with 2+ participants) · Cross-Department (points from runs with 2+ departments) · Department (one board per entry in Config.Departments).

Ranking rules

- Rank by points; ties go to fewer failed runs, then to whoever reached the score first.

- Officers need 3 or more completed runs in the window to appear.

- The top 25 are shown, and the viewer's own position is always pinned at the bottom.

- Boards are cached and refreshed every 60 seconds.

Privacy: officers can hide their name (callsign only) with a Profile toggle; their points still count for department totals.

## Department challenge

Every season is also a contest between all departments in Config.Departments (SAST vs FIB today). A department added mid-season joins at 0.

| Rule | Detail |
|---|---|
| Department score | Default: average season points per active officer (3+ completed runs), so a smaller department is not outscored on headcount alone. Config can switch to total or top10 (the sum of the 10 best officers) |
| Joint runs | Points from a cross-department run count for each participant's own department |
| Weekly bounty | Each Monday the server picks one objective at random from Config.Challenge.bounties (e.g. "Most Tactical missions", "Most cross-department runs"), and an admin can override it for that week. The department with the highest count per active officer wins a bonus of 10% of the challenge points its officers earned that week, added once when the week closes |
| Transfers | Points stay with the department the officer was in when the run ended |
| Tie-break | More completed runs, then more unit runs |
| Winner | "Season X Champions" banner on members' Home screen, a trophy badge for members with 3+ runs, and a Discord post |

Tablet: the Department Challenge screen shows each department's score bar in its own theme colour, weeks left, this week's bounty and the viewer's department's top 5 contributors.

## Mission Builder

Supervisors build missions on the tablet (Supervisor UI) and admins in the Admin UI: they choose every setting, place spots in the world, record routes by driving them, test, and publish. Nothing needs Lua editing or a restart, and each published mission is also saved as a Lua file that developers can edit.

Where: Supervisor UI → Mission Builder, or Admin UI → Missions → Builder. Which builder actions supervisors may use is set in Config.Permissions (its supervisor list: by default they build, test, publish and archive their own missions; admins can always do everything, including rolling back and breaking edit locks).

Flow

- New mission → pick up to 6 objective blocks, in the order officers will do them.

- Details → name, description, mission type (required; it sets the points and the base payout), difficulty (1–3 stars), min and max officers (1–4), time limit (2–20 min), start timeout (5–15 min), cooldown (5–60 min), "Available to" (departments from Config.Departments; none selected = every department), vehicle-damage penalties on or off (off is suggested when the mission has a pursuit or escort block or armed NPCs), optional items, and bonuses and penalties picked from the standard list in Config.Bonuses (a flat bonus or penalty is capped at 50 points, a percentage one at 25% of P; block settings such as a hostage-hit penalty keep their own ranges). There is no payout field.

- Block settings → every block has its own settings panel (tables below). Each value has the minimum, maximum and default shown, and the tablet will not accept anything outside that range. These ranges and defaults live in config/blocks.lua, so they can be changed without touching code.

- Place it in the world → the tablet closes into placement mode (see Placement tool) and reopens when done.

- Record routes → blocks that move along roads (escort, pursuit, checkpoint route) record a road route by driving it (see Route recording).

- Scaling → tick which counts scale with the tier; each block suggests a default.

- Test run → the builder plays it privately at any tier, in the same test mode admins use (see Admin test mode); points and cash are shown but not saved or paid. Publishing needs one passed test at the tier its maxOfficers reaches (for example Heavy for a 4-officer mission).

- Publish → the mission joins its type's pool for the chosen departments, and its Lua file is written.

Block settings

Every block also has a Presence range setting (50–800 m): how close partners must stay in runs with 2 or more participants. The defaults are in Anti-exploit → Presence range.

hostile_waves

| Setting | Range | Default |
|---|---|---|
| Waves | 1–6 | 3 |
| Hostiles per wave | 1–15 (every armed NPC in the mission counts toward 40 before scaling) | 7 |
| Next wave | when this many or fewer are alive (0–5), or after this long (30–300 s) | 2, or 90 s |
| Weapons | from Config.Builder.allowed.weapons | Pistol, Micro SMG |
| Accuracy | 5–60 | 25 |
| Armour | 0–100 | 0 |
| Health | 100–400 | 200 |
| Behaviour | Hold cover, Balanced or Push | Balanced |
| Surrender chance under 25% health | 0–100% | 30% |
| Ped models | from Config.Builder.allowed.peds | gang set |
| Boss | off, or model, health, armour and weapon | off |
| Block NPC traffic within | 0–200 m | 120 m |
| Spawn points | placed; at least 1.5 × the largest wave | — |

escort

| Setting | Range | Default |
|---|---|---|
| Route | recorded by driving (see Route recording) | — |
| Vehicle | from Config.Builder.allowed.escortVehicles | stockade |
| Speed | 20–120 km/h | 60 km/h |
| Driving style | Careful, Normal or Fast (always keeps to its lanes) | Normal |
| Vehicle toughness | × 0.5–3.0 health | × 1.5 |
| Fail if stopped for | 15–120 s | 60 s |
| Arrival radius | 10–50 m | 20 m |
| Ambush points | 1–10, placed on the route at least 150 m apart | 5 |
| Ambush waves | 1–5 | 2 |
| Cars per wave | 1–5 | 2 |
| Attackers per car | 1–4 | 2 |
| Attacker weapons, accuracy, armour | as hostile_waves | — |
| Stop points | 0–5, added with E while recording; the truck waits 10–60 s at each, and that wait never counts toward "Fail if stopped for" | none; 20 s wait |

pursuit

| Setting | Range | Default |
|---|---|---|
| Mode | Follow (stay close) or Stop (stop, then arrest) | Stop |
| Vehicles | 1–5 | 1 |
| Vehicle models | from Config.Builder.allowed.vehicles | sports set |
| Route | free flee, or a recorded road route (e.g. a race loop) | free flee |
| Speed and style | 40–160 km/h; Cautious or Reckless | 120 km/h, Reckless |
| Suspects per vehicle | 1–4 | 1 |
| Chance to flee on foot after the stop | 0–100% | 20% |
| Distance to hold (Follow mode) | 50–300 m | 150 m |
| Lost after | 150–600 m for 5–30 s | 250 m for 10 s |
| Duration | 60–600 s | 180 s |

checkpoint_route

| Setting | Range | Default |
|---|---|---|
| Checkpoints | 2–20, placed or recorded by driving | — |
| Use | all in order, or a random N | all |
| Radius | 3–20 m | 10 m |
| Stop at each for | 0–30 s | 10 s |
| Police vehicle required | yes / no | yes |
| Medal times | Gold, Silver and Bronze in seconds, or off | off |
| Contact penalty | 0–10 s per hit | 2 s |

interact_points

| Setting | Range | Default |
|---|---|---|
| Points | 1–10 placed | — |
| Use | all, or a random N | all |
| Label and progress time | text; 1–30 s | "Checking…"; 5 s |
| Animation | from Config.Builder.allowed.animations | clipboard |
| Logged result | off, or 2–4 choices with the correct one rolled by the server | off |

skill_check

| Setting | Range | Default |
|---|---|---|
| Checks | 1–8 | 4 |
| Difficulty of each | easy, medium or hard | easy, medium, medium, hard |
| Miss penalty | 0–120 s off the timer | 30 s |
| Fail after | 1–3 misses in a row | 2 |

protect_rescue

| Setting | Range | Default |
|---|---|---|
| NPCs | 1–6 | 3 |
| Models | from Config.Builder.allowed.peds | civilian set |
| Restrained | yes / no | yes |
| Time to free | 1–15 s | 6 s |
| Safe marker | placed | — |
| Penalty per hit | 0–100 | 50 |
| Fail if one dies | yes / no | yes |

flee_arrest

| Setting | Range | Default |
|---|---|---|
| Suspects | 1–10 | 1 |
| Surrender / flee / fight chances | percentages adding up to 100 | 50 / 30 / 20 |
| Armed chance and weapons | 0–100%; from the allowed list | 20%; pistol |
| Escape after | 200–800 m for 10–60 s | 400 m for 20 s |
| Gives up when | aimed at within 5–15 m (10 m by default), stunned, or a participant stays within 3 m for 3 s | all three |

search_area

| Setting | Range | Default |
|---|---|---|
| Starting circle | 200–1,000 m | 600 m |
| Clues | 1–5 | 3 |
| Circle after each clue | list of radii | 300, 150, 50 m |
| Fugitives | 1–5 | 1 |
| Runs when a participant is within | 10–60 m | 30 m |

Route recording

- Start it from the block's settings on the tablet. The tablet closes and the recording HUD appears; drive the route in any vehicle, at any speed — driving slowly is fine.

- Every 25 m the position is snapped to the nearest road node (GetClosestVehicleNodeWithHeading). Samples more than 8 m from any road (grass, pavement, car parks) are rejected with an "Off road" warning.

- The route is saved as road waypoints only: one at every junction or turn (heading change over 30°) and at least one every 150 m, with duplicates removed. The builder's speed, lane and exact line are never stored.

- At run time the NPC vehicle drives from waypoint to waypoint with normal lane-following driving (TaskVehicleDriveToCoordLongrange) at the speed and style set in the block. It follows the same roads, not the exact spots the builder drove.

- HUD keys while recording: E adds a stop point (escort only), Backspace undoes the last 100 m, P pauses and resumes, X finishes.

- After recording, the tablet shows the route on the map with its length. Test drive spawns the vehicle and sends it along the route at the chosen speed so the builder can watch or follow; any waypoint it fails to reach within 30 s is marked for re-recording.

- Checks: 0.8–8 km long; start and end at least 300 m apart (a race loop must end within 50 m of its start); a road path exists between each pair of waypoints (CalculateTravelDistanceBetweenPoints); no waypoint inside a no-build zone.

Route data as stored in an objective of the mission file. Speed and style are the block's own settings, so the same route format works for escort, pursuit and checkpoint_route:

route = {
  points = {            -- road waypoints from the recording, snapped to road nodes
    vec3(0.0, 0.0, 0.0),
    -- ...
  },
  stops = {             -- escort only: stop points added with E while recording
    { at = 12, wait = 20 },   -- waypoint index, seconds the truck waits there
  },
},
speed = 60,             -- km/h: the block's own speed setting
style = 'normal',       -- the block's own style setting; vehicles always keep to their lanes

Placement tool: a ghost preview of the ped, vehicle or marker follows your aim; scroll rotates, E places, Backspace undoes, Enter returns to the tablet. Areas are drawn as ox_lib zones. A spot that fails a check below shows red and cannot be placed.

Guardrails (checked while placing, and again by the server on publish)

- There is no payout field: a custom mission pays its type's payout (× its star multiplier) until an admin sets a mission payout.

- Only models, weapons, vehicles and animations in Config.Builder.allowed can be picked.

- At most 40 armed NPCs per mission before scaling, counting every block (hostile waves, escort attackers, and every flee_arrest suspect whenever its armed chance is above 0), with the running total shown in the builder; at run time the caps still apply (25 armed NPCs alive and 80 entities at any one moment).

- Spawn points must be on the ground (not in water, inside walls or in the air), at least 30 m from the start point, and outside the no-build zones (Config.Builder.noBuildZones: police stations, hospitals and the prison interior by default).

- Locations of the same mission must be at least 100 m apart, and each mission needs at least 3.

- Every objective has a minimum time (minSeconds, or the block's default), the time limit is 2–20 minutes, and every block must have its required points placed.

- A mission must pass a test run at the tier its maxOfficers reaches before it can be published.

Editing safety

- Only one person can edit a mission at a time: opening it locks it for 30 minutes, renewed while they keep editing. An admin can break the lock.

- Drafts autosave every 30 seconds.

- Editing a published mission works on a draft (the next version) while the published version stays live.

- Admins can roll a custom mission back to its previous version from Admin UI → Missions (restored from its .bak file).

Lifecycle: Draft → Tested → Published → Archived. Each run records the version it was played on. Built-in missions are read-only in the builder and can be duplicated into an editable copy. Every save, test, publish, archive and rollback is written to the audit log.

Lua export for developers — every publish writes missions/custom/<mission_id>.lua, in exactly the same shape as a built-in mission file (see Example files). Chances are written as fractions (30% becomes 0.30) and progress times in milliseconds (5 s becomes 5000), the units built-in files use.

- The server writes it with SaveResourceFile. A header comment lists the mission id, version, type, who published it and when.

- The file is the source of truth for a published custom mission: on start and on reload, the server loads every published custom mission from its file. If a file is missing, the server rewrites it from the database and warns.

- Publishing overwrites the file and keeps the previous one as <mission_id>.v<version>.lua.bak.

- A developer can edit the file and run /CrimsonPoliceAdmin reload. The server checks it against the same guardrails and saves it as a new version marked "edited in code".

- If the builder draft and the file both changed since the last publish, the reload keeps the file, saves the draft as <mission_id>.draft.lua.bak and records the conflict in the audit log.

- Payouts never come from the file: a payout field added by hand is ignored with a console warning.

- Archiving moves the file to missions/custom/archived/.

## Data model

Fourteen tables (prefix cp_) hold everything. Leaderboards are computed from cp_mission_runs, which has one row per participant per run, so every point and every payment traces back to the run that earned it.

-- sql/migrations/001_initial.sql: the full schema for a fresh install

CREATE TABLE IF NOT EXISTS cp_schema_migrations (   -- created by the migration runner before 001 runs
  version    INT PRIMARY KEY,                  -- the file's number, e.g. 1 for 001_initial.sql
  name       VARCHAR(100) NOT NULL,            -- the file name
  applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE cp_officers (
  citizenid       VARCHAR(50) PRIMARY KEY,     -- Qbox citizenid
  callsign        VARCHAR(32) NULL,            -- copy of metadata.callsign (set by SC-Police); display only
  rank_label      VARCHAR(40) NULL,            -- copy of the Qbox job grade name; display only
  display_name    VARCHAR(64) NULL,
  department      VARCHAR(32) NULL,            -- key from Config.Departments
  xp              INT NOT NULL DEFAULT 0,
  streak_days     TINYINT NOT NULL DEFAULT 0,
  last_complete   DATE NULL,
  grace_week      DATE NULL,                   -- start of the week the grace count below belongs to
  grace_used      TINYINT NOT NULL DEFAULT 0,  -- missed days forgiven in that week
  hide_name       TINYINT(1) NOT NULL DEFAULT 0,
  suspended_until DATETIME NULL                -- Crimson-Police suspension (separate from SC-Dispatch)
);

CREATE TABLE cp_operations (                   -- Cross-Department Missions
  id          INT AUTO_INCREMENT PRIMARY KEY,
  mission_id  VARCHAR(40) NOT NULL,
  launched_by VARCHAR(50) NOT NULL,            -- citizenid of the supervisor or admin
  status      ENUM('joining','running','waiting','completed','cancelled') NOT NULL DEFAULT 'joining',
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,  -- the last launch starts Config.CrossDept.cooldown
  ended_at    DATETIME NULL
);

CREATE TABLE cp_mission_runs (                 -- one row per participant per run
  id              INT AUTO_INCREMENT PRIMARY KEY,
  run_uuid        VARCHAR(36) NOT NULL,        -- shared by every participant of one run
  operation_id    INT NULL,                    -- set for Cross-Department Missions
  mission_type    VARCHAR(32) NOT NULL,        -- a type key, 'manual_award' or 'goal'
  mission_id      VARCHAR(40) NOT NULL,
  mission_version SMALLINT NULL,               -- custom missions only
  location_label  VARCHAR(64) NULL,            -- the drawn location
  citizenid       VARCHAR(50) NOT NULL,
  department      VARCHAR(32) NOT NULL,        -- participant's department when the run ended
  season_id       INT NULL,
  participants    TINYINT NOT NULL DEFAULT 1,
  departments_n   TINYINT NOT NULL DEFAULT 1,  -- distinct departments on the run
  tier            ENUM('standard','reinforced','heavy','major','critical') NOT NULL DEFAULT 'standard',  -- points and cash tier used for this row
  modifier        VARCHAR(20) NULL,
  state           ENUM('completed','failed','abandoned') NOT NULL,
  end_reason      VARCHAR(24) NOT NULL,        -- how this participant's run ended (see Mission lifecycle)
  points_base     SMALLINT NOT NULL,           -- P = the type's config points x star multiplier
  bonus_points    SMALLINT NOT NULL DEFAULT 0,
  penalty_points  SMALLINT NOT NULL DEFAULT 0,
  final_points    SMALLINT NOT NULL DEFAULT 0,
  cash_base       INT NOT NULL DEFAULT 0,      -- B, locked when the type was accepted
  cash_multiplier DECIMAL(4,2) NOT NULL DEFAULT 1.00,
  cash_paid       INT NOT NULL DEFAULT 0,
  cash_status     ENUM('none','held','pending','paying','paid','capped','unfunded','forfeited') NOT NULL DEFAULT 'none',
  duration_s      SMALLINT NOT NULL DEFAULT 0,
  breakdown       JSON NULL,                   -- points and cash breakdown shown on the tablet
  flagged         TINYINT(1) NOT NULL DEFAULT 0,
  flag_reason     VARCHAR(64) NULL,            -- why: 'outside_help', 'too_fast', 'speed', 'presence' or 'unexpected_event'
  voided          TINYINT(1) NOT NULL DEFAULT 0,
  created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_board  (created_at, citizenid, voided),
  INDEX idx_season (season_id, citizenid),
  INDEX idx_dept   (season_id, department),
  INDEX idx_draw   (citizenid, mission_type, created_at),
  INDEX idx_run    (run_uuid)
);

CREATE TABLE cp_mission_runs_archive LIKE cp_mission_runs;   -- rows older than Config.Retention.runArchiveMonths

CREATE TABLE cp_seasons (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  name      VARCHAR(64) NOT NULL,
  starts_at DATETIME NOT NULL,
  ends_at   DATETIME NULL,
  active    TINYINT(1) NOT NULL DEFAULT 0
);

CREATE TABLE cp_badges (
  citizenid VARCHAR(50) NOT NULL,
  badge_id  VARCHAR(40) NOT NULL,
  earned_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (citizenid, badge_id)
);

CREATE TABLE cp_custom_missions (
  id                   VARCHAR(40) PRIMARY KEY,
  mission_type         VARCHAR(32) NOT NULL,  -- required; sets points and base payout
  status               ENUM('draft','published','archived') NOT NULL DEFAULT 'draft',
  published_version    SMALLINT NULL,         -- the version players run now
  published_definition JSON NULL,             -- copy of the published file
  draft_version        SMALLINT NULL,         -- the next version, being edited in the builder
  draft_definition     JSON NULL,             -- autosaved every Config.Builder.autosaveSeconds
  draft_tested         TINYINT(1) NOT NULL DEFAULT 0,  -- 1 = passed a test run at the tier its maxOfficers reaches
  file_path            VARCHAR(128) NULL,     -- missions/custom/<id>.lua
  edited_in_code       TINYINT(1) NOT NULL DEFAULT 0,
  locked_by            VARCHAR(50) NULL,      -- citizenid editing it now
  locked_until         DATETIME NULL,         -- edit lock expiry (Config.Builder.editLockMinutes)
  created_by           VARCHAR(50) NOT NULL,
  updated_by           VARCHAR(50) NOT NULL,
  updated_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE cp_dept_bounties (
  season_id INT NOT NULL,
  week      TINYINT NOT NULL,
  objective VARCHAR(40) NOT NULL,             -- key from Config.Challenge.bounties
  winner    VARCHAR(32) NULL,                 -- department key
  PRIMARY KEY (season_id, week)
);

CREATE TABLE cp_type_payouts (                 -- base cash payout per mission type
  mission_type VARCHAR(32) PRIMARY KEY,        -- key from Config.MissionTypes
  amount       INT NOT NULL,
  admin_locked TINYINT(1) NOT NULL DEFAULT 0,  -- 1 = set by an admin: permanent, read-only for supervisors
  updated_by   VARCHAR(50) NOT NULL,
  updated_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP  -- also times the supervisor cooldown
);

CREATE TABLE cp_mission_payouts (              -- admin only; permanent until an admin clears it
  mission_id VARCHAR(40) PRIMARY KEY,
  amount     INT NOT NULL,
  set_by     VARCHAR(50) NOT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE cp_disputes (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  run_id     INT NOT NULL,                     -- cp_mission_runs.id
  citizenid  VARCHAR(50) NOT NULL,
  reason     VARCHAR(255) NOT NULL,
  goes_to    ENUM('supervisor','admin') NOT NULL, -- flagged or voided run: supervisor; failed run: admin
  status     ENUM('open','approved','rejected') NOT NULL DEFAULT 'open',
  handled_by VARCHAR(50) NULL,                 -- never a participant of that run
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  handled_at DATETIME NULL
);

CREATE TABLE cp_mission_tests (                -- admin test log (see Admin test mode)
  id              INT AUTO_INCREMENT PRIMARY KEY,
  mission_id      VARCHAR(40) NOT NULL,
  mission_version SMALLINT NULL,               -- custom missions only
  location_index  TINYINT NOT NULL,
  tier            ENUM('standard','reinforced','heavy','major','critical') NOT NULL,
  testers         TINYINT NOT NULL DEFAULT 1,
  result          ENUM('passed','failed') NOT NULL,
  note            VARCHAR(255) NULL,
  tested_by       VARCHAR(50) NOT NULL,        -- citizenid of the admin
  created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_mission (mission_id, location_index, created_at)
);

CREATE TABLE cp_audit (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  actor      VARCHAR(50) NOT NULL,             -- citizenid, or 'console'
  role       ENUM('supervisor','admin','console') NOT NULL,
  category   ENUM('audit','flags','builder','operations') NOT NULL DEFAULT 'audit', -- picks the webhook
  action     VARCHAR(40) NOT NULL,
  target     VARCHAR(64) NULL,
  old_value  VARCHAR(64) NULL,
  new_value  VARCHAR(64) NULL,
  reason     VARCHAR(255) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

sql/migrations/001_initial.sql creates every table (see Database upgrades). A mission type with no row in cp_type_payouts uses the payout from Config.MissionTypes, and the Weekly Boss uses Config.Events.weeklyBoss.payout until an admin sets a mission payout. Published custom missions are loaded from their Lua files; the database keeps drafts, metadata and edit locks. callsign and rank_label in cp_officers are copies refreshed from Qbox whenever the officer loads in or opens the tablet, so boards can show officers who are offline; Crimson-Police never writes them back. Voided runs stay for audit but are left out of every board. At each daily reset the server moves runs older than Config.Retention.runArchiveMonths (12) into cp_mission_runs_archive and deletes audit rows older than Config.Retention.auditDays (180); 0 turns either off. XP and badges live in cp_officers and cp_badges, so archiving never changes them or the all-time board.

Database upgrades

Crimson-Police creates and upgrades its own tables, so an update never needs a manual SQL import and never wipes run history, leaderboards, payouts or custom missions.

- Every schema change is a numbered file in sql/migrations/: 001_initial.sql (the schema above), then 002_<what_changed>.sql, 003_… and so on. A released file is never edited; every later change gets a new file.

- On start, modules/migrations/ creates cp_schema_migrations if it is missing, runs every file whose number is not recorded there yet, in order, and records each one when it finishes. Other modules wait for it before their first query.

- The runner reads each file with LoadResourceFile, splits it into statements at each ; that ends a line, and runs them one at a time with MySQL.query.await. Migration files never put a ; inside a comment or a string.

- If a statement fails, the runner stops, prints the file and the error, and Crimson-Police does not start, so it never runs on a half-upgraded database. MySQL applies table changes at once and can't roll them back, so migrations are written to be safe to run again (CREATE TABLE IF NOT EXISTS, and IF NOT EXISTS on columns and indexes where the database supports it).

- Migrations only add: new tables, new columns with defaults, new indexes. They never DROP or TRUNCATE a table, and never delete rows of runs, officers, seasons, badges, payouts, disputes, audit entries, tests or custom missions. To change a column, a migration adds the new column and copies the data across; the old column stays.

- On start the console prints "Crimson-Police database at version N" and each file it applied.

- Updating the resource: replace the code but keep your config/, logos/ and missions/custom/ folders. If a custom mission file goes missing anyway, the server rewrites it from the database on start.

## Architecture, folders & events

The server owns runs, draws, scaling, points and cash. The client runs objectives and reports progress, which the server validates before awarding anything. Every feature has its own folder, so each part can be edited and debugged on its own.

Folder layout

Crimson-Police/
  fxmanifest.lua
  config/config.lua                  every setting (see Config)
  config/blocks.lua                  Mission Builder block ranges and defaults
  shared/init.lua                    the CP namespace, RegisterMission(), shared helpers
  shared/locale.lua                  loads locales/en.json
  locales/en.json                    all player-facing text
  logos/                             department logos: sast.png, fib.png, ...
  missions/builtin/index.lua         list of built-in mission ids, read by the server
  missions/builtin/<mission_id>.lua  one file per built-in mission
  missions/custom/<mission_id>.lua   one file per custom mission, written by the Mission Builder
  missions/custom/archived/          archived custom missions
  modules/<feature>/server.lua       one folder per feature (see the table below)
  modules/<feature>/client.lua       only where the feature has client code
  blocks/<block_id>/server.lua       one folder per objective block
  blocks/<block_id>/client.lua
  web/src/                           React + TypeScript: officer/, supervisor/, admin/, hud/, shared/
  web/dist/                          Vite build loaded by fxmanifest
  sql/migrations/                    numbered database upgrades: 001_initial.sql, 002_..., applied in order on start

Feature folders

| Folder | Files | What it owns |
|---|---|---|
| modules/access/ | server, client | Departments, roles, duty, active job, rank and callsign, suspension checks |
| modules/permissions/ | server | Config.Permissions; every supervisor and admin action asks this module first |
| modules/tablet/ | server, client | Opening and closing the three UIs and the mission HUD; session, theme and logo data; tablet prop |
| modules/schedule/ | server | The daily and weekly resets (Config.Time) and the retention job; other modules subscribe to them |
| modules/draw/ | server | Mission pools, the random draw, location reservations |
| modules/runs/ | server, client | Run lifecycle, end reasons, start timeout, abandon, cooldowns, server run caps, run host, cleanup |
| modules/route/ | server, client | The start route: sampling the GPS line, off-route warnings and abandons, recalculations, the server drift check |
| modules/calls/ | server | Real calls vs NPC calls, ending runs on real calls, the 60-second rule, "On a call" |
| modules/alerts/ | server | The alert-suppression flag (crimsonArena state bag) and the call backstop (shots fired, person down, person dead) |
| modules/downed/ | server, client | Downed checks, Failed results, pick-up and drop-off, EMS requests |
| modules/units/ | server, client | Unit invites and membership |
| modules/operations/ | server, client | Cross-Department Missions, the board lock and the launch cooldown |
| modules/scaling/ | server | Tiers and scaled counts |
| modules/scoring/ | server | Points, streaks, XP, XP levels, badges |
| modules/goals/ | server | Daily and weekly goals |
| modules/cash/ | server | Cash formula and payments, including pending payments |
| modules/payouts/ | server | Editable type and mission payouts, supervisor limits |
| modules/leaderboard/ | server | Boards and caching |
| modules/challenge/ | server | Department challenge and bounties |
| modules/events/ | server | Type of the Day, modifiers, Weekly Boss |
| modules/builder/ | server, client | Mission Builder, block settings, placement tool, route recording and test drive, edit locks, autosave, versions and rollback, Lua export, custom mission loading |
| modules/disputes/ | server | Officer disputes and where they go |
| modules/admin/ | server | Supervisor and admin actions, /CrimsonPoliceAdmin, audit log, webhooks |
| modules/anticheat/ | server | Objective validation, presence and idle checks, flagged runs |
| modules/integrations/qbx/ | server, client | Every qbx_core call |
| modules/integrations/sc_dispatch/ | server | Responding listener, mdt_dispatch lookup, shots-fired and person-down listeners, ClearNotification, suspension check |
| modules/integrations/sc_ambulance/ | server, client | EMS on duty, the revive event, the EMS request |
| modules/integrations/renewed_banking/ | server | Bank transaction entries and society accounts |
| modules/migrations/ | server | Applies new files in sql/migrations/ on start and records them in cp_schema_migrations |
| modules/testing/ | server, client | Admin test mode: test runs, test controls, the debug overlay and the test log |

Module rules

- Each module exposes one global table (e.g. CP.Cash) and keeps everything else local. Other modules only call the functions on that table.

- Only modules/integrations/* may call qbx_core, sc-police, sc-dispatch, sc-ambulance, sc-multijob or Renewed-Banking, or read their database tables, so a change in one of those resources is fixed in one place. ox_lib, ox_target, ox_inventory and oxmysql may be called directly.

- Qbox only: modules/integrations/qbx/ uses only the qbx_core exports and events listed in the Appendix. Never exports['qb-core'], GetCoreObject() or QBCore.Functions, even though some installed resources still use them.

- Only modules/alerts/ sets or clears the crimsonArena state bag, and only modules/permissions/ decides whether a role may do an action.

- Every block folder has the same interface: server.lua creates and deletes that step's networked NPCs and vehicles (OneSync server-side CreatePed / CreateVehicle) and validates its objective events; client.lua shows markers, blips, ox_target options and UI, and on the run host's client runs the NPC AI. A block's builder ranges and defaults come from Config.Blocks[<block_id>].

- If the run host leaves, the next participant becomes host; if nobody is left, the server deletes everything.

- With Config.Debug = true, each module prints its own tagged lines, e.g. [crimson-police:cash].

- fxmanifest.lua loads, in order: config/config.lua, config/blocks.lua, shared/*.lua, modules/**/server.lua or client.lua, then blocks/**/server.lua or client.lua. Mission files are not listed as scripts: at start and on reload the server reads every built-in mission named in missions/builtin/index.lua and every published custom mission (its file_path in cp_custom_missions) with LoadResourceFile, runs it, and sends the definitions to clients, so /CrimsonPoliceAdmin reload updates both without a restart.

- Every module waits for CP.Migrations.ready() before its first database query, so nothing reads a table before its migration has run.

Net events (all prefixed crimson-police:; runId is always the run's run_uuid, shared by every participant)

| Event | Direction | Payload | Notes |
|---|---|---|---|
| server:acceptType | C → S | missionType (a type key, or 'weekly_boss' for the Weekly Boss card) | Leader only; the server checks role, duty, unit, cooldowns, a real call in progress, the server run caps and the Cross-Department lock, closes invites, then draws and reserves the location |
| server:unitInvite / server:unitRespond / server:unitLeave | C → S | targetSrc / accepted / — | Any department; up to 4 members; invites only before the type is accepted |
| server:joinOperation | C → S | operationId | Joins the active Cross-Department Mission |
| client:start | S → C | runId, drawn mission, location, start point, expected tier, seed, host, test | Sent at accept. Every participant gets the same seed; host says whose client runs the NPC AI; the client sets the start route; test is true for test runs |
| server:routeStatus | C → S | runId, metres from the start route, coords | Every 2 s until that participant reaches the start; no report for 10 s counts as off route |
| server:recalcRoute | C → S | runId | Allowed up to 2 times per participant per run; when allowed, the client samples a new line from where it is |
| client:routeWarning | S → C | runId, seconds left (nil clears it) | The off-route warning on the HUD and the tablet |
| client:inProgress | S → C | runId, tier, scaled counts | Sent to every participant when the run moves to In progress; the HUD switches to the objectives |
| server:objective | C → S | runId, objectiveId, evidence (coords, entity netId, time) | Rate-limited and validated |
| server:abandon | C → S | runId | Always a normal abandon with the type cooldown; real calls end runs by themselves |
| server:dispute | C → S | rowId (the officer's own cp_mission_runs.id), reason | Own flagged, voided or failed runs from the last 48 hours only |
| client:operation | S → all officers | state (launched, started, ended), mission label | Updates every Mission Board |
| client:pickup | S → C | runId, drop-off coords | Fade out; the server triggers SC-Ambulance's revive; the client moves to the drop-off and fades in |
| client:requestEMS | S → C | runId | Sends SC-Ambulance's EMS request from the downed officer's client, after the server has removed their flag |
| client:runEnded | S → C | runId, result, end_reason, points and cash breakdown | Ends that participant's run on their client (cleanup and a HUD message, e.g. "Mission ended — you're on a real call") and shows the result screen |
| client:tierChanged | S → C | runId, new tier, points and cash tier | Sent to everyone still on the run when the team shrinks; the HUD shows the new tier |

Supervisor and admin actions use their own events (crimson-police:server:sup:* and crimson-police:server:admin:*), and each re-checks the sender's role and Config.Permissions on the server.

Callbacks (ox_lib): crimson-police:getSession (role, department, rank, callsign, theme, logo URL, the actions this player may use), crimson-police:getMissionTypes, crimson-police:getBoard (period, filter), crimson-police:getProfile (citizenid), crimson-police:getMissionList (supervisors and admins only).

Exports

| Export | Side | Purpose |
|---|---|---|
| IsOnMission(src) | Server | True from the moment the player's run is Accepted until it ends; other scripts can use it |
| GetDepartment(src) | Server | Returns the player's department key, or nil |
| OpenTablet() | Client | Opens the Officer UI with the same checks as /CrimsonPolice |

There is deliberately no export for awarding points: only goal rewards and an admin's logged manual award add points outside a run.

## Config

Every threshold in this spec is a value in config/config.lua, in config/blocks.lua for Mission Builder settings, or, for per-mission values, in that mission's file, so the server owner can tune the system without touching code. If this document and the config disagree, the config wins.

Config = {}

Config.Debug  = false            -- true = each module prints tagged debug lines
Config.Locale = 'en'

-- ── Tablet and commands ─────────────────────────────────────────────────────
Config.Tablet = {
  title        = 'Crimson-Police',       -- app title on every screen
  command      = 'CrimsonPolice',        -- opens the Officer UI
  adminCommand = 'CrimsonPoliceAdmin',   -- opens the Admin UI; also takes subcommands
  keybind      = '',                     -- default key ('' = none; players can bind it in GTA settings)
  item         = false,                  -- ox_inventory item name that also opens the tablet, or false
  prop         = 'prop_cs_tablet',       -- prop held while the Officer UI is open
}

Config.AdminAce   = 'crimsonpolice.admin'   -- the admin permission; supervisors come from job grade
Config.AdminTheme = { primary = '#a4161a', accent = '#e5383b', background = '#0b090a', surface = '#161a1d', text = '#f5f3f4' }

-- ── Permissions ─────────────────────────────────────────────────────────────
-- What supervisors may do. Admins can always do every admin action.
-- false hides the action in the Supervisor UI, and the server refuses it.
Config.Permissions = {
  supervisor = {
    setTypePayout   = true,    -- within Config.Payouts limits; never a type an admin has set
    launchCrossDept = true,    -- launch, start now, relaunch and cancel
    forceRecall     = true,
    reviewFlagged   = true,    -- approve or void flagged runs involving their department
    handleDisputes  = true,    -- disputes about flagged or voided runs in their department
    builderEdit     = true,    -- create, edit, record routes and test their own missions
    builderPublish  = true,    -- publish their own tested drafts
    builderArchive  = true,    -- archive or restore their own missions
    builderEditAny  = false,   -- also edit, publish and archive other people's custom missions
    builderRollback = false,   -- roll a custom mission back to its previous version
    breakEditLock   = false,   -- unlock a mission someone else is editing
  },
  -- Always admin-only, whatever is set above: single-mission payouts, clearing
  -- admin payouts, manual awards, disputes about failed runs, voiding any run,
  -- seasons, the bounty override, suspensions, reloading mission files and test runs.
  -- Nobody may approve, void or answer a dispute about a run they took part in.
}

-- ── Departments ─────────────────────────────────────────────────────────────
-- Every entry is used automatically for access, the tablet name, colours and
-- logo watermark, leaderboards, the department challenge, unit invites and the
-- Mission Builder. Add a block, put its logo in logos/, restart. No code or SQL changes.
Config.Departments = {
  sast = {
    label           = 'San Andreas State Troopers',  -- shown in the tablet header
    short           = 'SAST',                        -- tag on boards, units and badges
    jobs            = { 'sast' },                    -- Qbox job names (as in sc-police / sc-dispatch)
    supervisorGrade = 3,                             -- Qbox grade level; set to your real grade
    societyAccount  = 'sast',                        -- only used when Config.Cash.source = 'society'
    theme = {
      primary    = '#1f4e8c',   -- header, buttons, active tab, progress bars
      accent     = '#f2c230',   -- highlights, badges, focus outlines
      background = '#0d1522',   -- tablet body
      surface    = '#152235',   -- cards, tables, dialogs
      -- text    = '#ffffff',   -- optional; picked automatically for contrast when left out
    },
    logo = {
      file      = 'sast.png',   -- file in logos/ (or use url = 'https://...')
      watermark = true,         -- draw the logo behind every screen
      opacity   = 0.08,         -- 0.0 to 0.25
      size      = 0.6,          -- share of the tablet height
      grayscale = false,
    },
  },
  fib = {
    label           = 'Federal Investigation Bureau',
    short           = 'FIB',
    jobs            = { 'fib' },
    supervisorGrade = 3,
    societyAccount  = 'fib',
    theme = { primary = '#1c2541', accent = '#c9a227', background = '#0b0c10', surface = '#1a1b24' },
    logo  = { file = 'fib.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
  },
  -- Example: to add BCSO, uncomment and edit this block, then put bcso.png in logos/ and restart.
  -- bcso = {
  --   label = "Blaine County Sheriff's Office", short = 'BCSO', jobs = { 'bcso' },
  --   supervisorGrade = 3, societyAccount = 'bcso',
  --   theme = { primary = '#5c4033', accent = '#d4a017', background = '#14100c', surface = '#231c16' },
  --   logo  = { file = 'bcso.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
  -- },
}

-- ── Mission types ───────────────────────────────────────────────────────────
-- points: leaderboard points, config only (never editable in-game).
-- payout: default base cash payout. Supervisors and admins change it in-game;
-- admin-set values are stored permanently in cp_type_payouts.
Config.MissionTypes = {
  patrol        = { label = 'Patrol',        points = 60,  payout = 250 },
  training      = { label = 'Training',      points = 100, payout = 350 },
  investigation = { label = 'Investigation', points = 160, payout = 600 },
  tactical      = { label = 'Tactical',      points = 200, payout = 800 },
}

Config.DisabledMissions = {}   -- built-in mission ids to turn off, e.g. { 'prison_break' }

-- ── Difficulty (stars) ──────────────────────────────────────────────────────
-- Multipliers by a mission's difficulty: index 1, 2 or 3 stars.
-- 1.0 = stars change nothing, so a builder can't raise pay or points by picking 3 stars.
Config.Difficulty = {
  pointsByStars = { 1.0, 1.0, 1.0 },
  cashByStars   = { 1.0, 1.0, 1.0 },
}

-- ── Cash ────────────────────────────────────────────────────────────────────
Config.Cash = {
  account   = 'bank',     -- 'bank' or 'cash'
  source    = 'server',   -- 'server' (new money) or 'society' (the department's Renewed-Banking account)
  minPayout = 0,          -- limits for any base payout set in-game
  maxPayout = 25000,
  dailyCap  = 0,          -- max cash per officer per day; 0 = no cap
}

-- ── Payout editing ──────────────────────────────────────────────────────────
Config.Payouts = {
  supervisorRange    = { 0.5, 2.0 },  -- supervisors: 50%–200% of the type's payout in Config.MissionTypes
  supervisorCooldown = 1800,          -- seconds between changes to the same type (any supervisor)
  requireReason      = true,          -- a reason is required for every payout change
}

-- ── Scaling by participants ─────────────────────────────────────────────────
-- The first row whose maxParticipants >= the participant count is used.
Config.Scaling = {
  { maxParticipants = 1, tier = 'standard',   count = 1.0,  accuracy = 0,  armour = 0,  points = 1.00, cash = 1.00 },
  { maxParticipants = 2, tier = 'reinforced', count = 1.25, accuracy = 5,  armour = 10, points = 1.10, cash = 1.15 },
  { maxParticipants = 4, tier = 'heavy',      count = 1.5,  accuracy = 10, armour = 25, points = 1.15, cash = 1.30 },
  { maxParticipants = 6, tier = 'major',      count = 2.0,  accuracy = 15, armour = 50, points = 1.20, cash = 1.50 },
  { maxParticipants = 8, tier = 'critical',   count = 2.5,  accuracy = 20, armour = 75, points = 1.25, cash = 1.75 },
}
Config.CrossDepartmentPoints = 1.10    -- points multiplier when 2+ departments are on a run

-- When the team shrinks mid-run (see When someone leaves mid-run)
Config.Rescale = {
  enabled        = true,   -- NPCs not yet spawned use the tier for the team that's left
  keepPayTierFor = { 'real_call', 'force_recall', 'downed' },  -- leave reasons that keep the points and cash tier
}

Config.Limits = {
  maxUnitSize           = 4,
  maxArmedAlive         = 25,    -- armed NPCs alive at any one moment per run
  maxEntities           = 80,    -- spawned entities at any one moment per run
  corpseCleanup         = 30,    -- seconds before dead NPCs and wrecked vehicles are deleted
  maxCompletionsHour    = 8,
  abandonCooldown       = 300,   -- seconds; covers the whole mission type
  startTimeout          = 600,   -- default seconds to reach the start (a mission can override it)
  maxConcurrentRuns     = 12,    -- runs active server-wide at once; Cross-Department Missions don't count
  maxConcurrentTactical = 4,     -- of those, Tactical runs
  reserveLocations      = true,  -- a location in use by one run can't be drawn for another
}

-- ── Police vehicles ─────────────────────────────────────────────────────────
-- Used wherever a mission needs "a police vehicle" (Beat Patrol, EVOC Course,
-- and checkpoint_route with "Police vehicle required" on).
Config.PoliceVehicles = {
  classes = { 18 },   -- GTA vehicle classes; 18 = Emergency
  models  = {},       -- extra model names for police cars outside class 18 (e.g. add-on unmarked cars)
}

-- ── Route to the start ──────────────────────────────────────────────────────
Config.Route = {
  sampleEvery   = 50.0,    -- metres between points taken from the GPS route
  reportEvery   = 2,       -- seconds between client reports
  reportTimeout = 10,      -- no report for this long counts as off route
  maxDeviation  = 120.0,   -- metres from the line before a participant is off route
  warnAfter     = 10,      -- seconds off route before the warning
  abandonAfter  = 30,      -- seconds off route in one stretch before Abandoned (back on route resets it)
  maxRecalcs    = 2,       -- Recalculate route taps per participant per run
  maxDrift      = 1000.0,  -- server check: metres further from the start than the closest they have been
}

-- ── Real calls ──────────────────────────────────────────────────────────────
Config.Calls = {
  npcCallPrefix      = 'npccall-',   -- SC-NPCPolice call ids start with this; those calls never end a run
  ownRunCallPrefixes = { 'playerdown_', 'playerdead_', 'emsdown_', 'emshelp_', 'panic_' }, -- about a participant: not real calls for their partners
  dodgeWindow        = 60,           -- un-marking responding within this many seconds makes it a normal abandon
  respondingExpiry   = 1200,         -- seconds; a responding entry with no update expires (auto-cleared calls fire no event)
}

-- ── Alert suppression ───────────────────────────────────────────────────────
-- The flag is the crimsonArena state bag, which SC-Dispatch and SC-Ambulance
-- already check; its name is fixed in those resources, so it is not configurable.
Config.Alerts = {
  backstopRadius = 300.0,   -- clear a shots-fired call from a participant within this many metres of their mission (person-down and dead calls are cleared while the flag is on)
  backstopDelay  = 1,       -- seconds to wait for SC-Dispatch to create the call before clearing it
}

-- ── Downed participants ─────────────────────────────────────────────────────
Config.Downed = {
  checkEvery  = 2,      -- seconds between downed checks
  pickupDelay = 15,     -- seconds down, with no EMS on duty, before the pick-up
  dropOffs    = {       -- the nearest one is used; defaults are SC-Ambulance's check-in points
    vec3(308.19, -595.35, 43.29),     -- Pillbox Hill
    vec3(-254.54, 6331.78, 32.43),    -- Paleto Bay
  },
}

-- ── Anti-exploit ────────────────────────────────────────────────────────────
Config.AntiCheat = {
  maxSpeed       = 80.0,    -- m/s between objective events before a run is flagged
  presenceRadius = 150.0,   -- runs with 2+ participants: fallback presence range for a block with none of its own...
  presenceShare  = 0.70,    -- ...for this share of the run to earn points and cash
  idleCheck      = 180,     -- seconds after the run moves to In progress to remove participants who haven't reached the start
  jobRecheck     = 10,      -- seconds between active-job and duty re-checks during a run
  outsideKillsToFlag = 1,   -- kills of mission NPCs by players who aren't on the run that flag it for review
  voidsToSuspend = 3,       -- this many voided runs...
  voidWindowDays = 30,      -- ...within this many days...
  suspendDays    = 7,       -- ...suspends the officer for this many days
}

-- ── Cross-Department Missions ───────────────────────────────────────────────
Config.CrossDept = {
  enabled         = true,
  minParticipants = 2,
  maxParticipants = 8,
  joinWindow      = 300,     -- seconds until joining closes (or the launcher taps Start now)
  idleCancel      = 1800,    -- auto-cancel after this long with no run in progress
  cooldown        = 1800,    -- seconds between launches, server-wide
}

-- ── Random draw ─────────────────────────────────────────────────────────────
Config.Draw = {
  avoidLast       = 1,       -- never repeat the last mission in that type
  avoidLastLarge  = 2,       -- skip the last two when the pool has largePool+ missions
  largePool       = 4,
  playerClearance = 75.0,    -- skip locations with a non-participant within this many metres
}

-- ── Time ────────────────────────────────────────────────────────────────────
-- Hour (0–23, server time) of the daily reset: Type of the Day, daily goals,
-- streak days, the daily cash cap and the retention job. Weekly things reset
-- at this hour on Config.Leaderboard.weekStartsOn.
Config.Time = { resetHour = 0 }

-- ── Scoring, XP levels and goals ────────────────────────────────────────────────
Config.Scoring = {
  scoreCap     = 2.0,        -- × P
  streakStep   = 0.05,
  streakMax    = 0.25,
  streakGraceDays = 1,       -- missed days per week that don't reset the streak (0 = off)
  failedCredit = 0.25,
  common = {
    fastShare       = 0.75,  -- finished within this share of the time limit...
    fastBonus       = 0.20,  -- ...earns this share of P
    noDamage        = 10,
    firstRun        = 15,
    heavyDamage     = -25,
    pedestrianHit   = -30,
    lightsSiren     = -10,   -- Beat Patrol and Business Check only
    shotSurrendered = -20,
    noDamageAbove   = 950,   -- engine and body health above this earns noDamage
    heavyDamageBelow = 500,  -- body health below this costs heavyDamage
  },
}

-- ── Bonuses and penalties ───────────────────────────────────────────────────
-- The standard list, and the only one the Mission Builder offers. kind 'points'
-- = flat points (each = per occurrence); kind 'pct' = a share of P. block = the
-- block the mission must contain (none = any mission). Ids with positive values go in a mission file's bonuses,
-- negative ones in its penalties; either may override the value with points or pctOfPoints.
-- Labels live in locales/en.json. Built-in missions may also use the extra
-- bonuses written on their mission cards.
Config.Bonuses = {
  no_participant_downed = { kind = 'pct',    value = 0.10 },
  no_weapons_fired      = { kind = 'points', value = 10 },
  hostile_arrested      = { kind = 'points', value = 5,    each = true, block = 'hostile_waves' },
  suspect_alive         = { kind = 'points', value = 15,   block = 'flee_arrest' },
  no_hostage_hurt       = { kind = 'points', value = 15,   block = 'protect_rescue' },
  vehicle_stopped_fast  = { kind = 'points', value = 15,   block = 'pursuit' },          -- stopped within 2 minutes of the start
  truck_healthy         = { kind = 'pct',    value = 0.10, block = 'escort' },           -- arrives above 50% health
  clues_first           = { kind = 'points', value = 10,   block = 'search_area' },      -- every clue checked before the first arrest
  no_missed_checks      = { kind = 'points', value = 15,   block = 'skill_check' },
  correct_log           = { kind = 'points', value = 5,    each = true, block = 'interact_points' },
  wrong_log             = { kind = 'points', value = -5,   each = true, block = 'interact_points' },  -- penalty
  hard_ram              = { kind = 'points', value = -10,  each = true, block = 'pursuit' },          -- penalty: ramming at over 100 km/h
}

Config.XPLevels = {   -- cosmetic badges only; never the Qbox rank
  { label = 'Probationary',   xp = 0,     badge = 'grey' },
  { label = 'Patrol Officer', xp = 1000,  badge = 'bronze' },
  { label = 'Senior Patrol',  xp = 5000,  badge = 'silver' },
  { label = 'Veteran',        xp = 15000, badge = 'gold' },
  { label = 'Elite',          xp = 40000, badge = 'platinum' },
}

Config.Badges = {            -- achievement badge counts
  ironWheels     = 20,   -- completed runs with no vehicle damage
  sharpshooter   = 10,   -- Gang Shootouts with no participant downed
  roadWarrior    = 100,  -- Patrol missions
  partnerInCrime = 50,   -- unit runs
  jointTaskForce = 10,   -- runs with 2 or more departments
}

Config.Goals = {
  dailyPoints  = 50,
  weeklyPoints = 200,
  daily = {
    { id = 'patrol_2', label = 'Complete 2 Patrol missions',      type = 'patrol', count = 2 },
    { id = 'any_3',    label = 'Complete 3 missions of any type', count = 3 },
    { id = 'unit_1',   label = 'Complete 1 unit run',             unit = true, count = 1 },
  },
  weekly = {
    { id = 'tactical_5', label = 'Complete 5 Tactical missions',     type = 'tactical', count = 5 },
    { id = 'cross_2',    label = 'Complete 2 cross-department runs', crossDepartment = true, count = 2 },
    { id = 'any_15',     label = 'Complete 15 missions',             count = 15 },
  },
}

-- ── Leaderboard ─────────────────────────────────────────────────────────────
Config.Leaderboard = {
  cacheSeconds  = 60,
  minRunsToRank = 3,
  topN          = 25,
  weekStartsOn  = 'monday',
  seasonWeeks   = 8,         -- suggested season length for "weeks left"; an admin ends the season
}

-- ── Special events ──────────────────────────────────────────────────────────
Config.Events = {
  typeOfTheDay   = true,
  todMultiplier  = 2.0,      -- points only
  modifierChance = 0.25,
  modifierPoints = 0.25,     -- +25% of P
  modifierCash   = 1.25,     -- × cash
  armoredArmour  = 50,       -- Armored Hostiles: extra armour on armed NPCs (Tactical only)
  timeCrunchCut  = 0.25,     -- Time Crunch: share of the time limit removed
  weeklyBoss     = { enabled = true, days = { 'friday', 'saturday', 'sunday' }, points = 500, payout = 2500 },
}

-- ── Department challenge ────────────────────────────────────────────────────
Config.Challenge = {
  enabled       = true,
  scoring       = 'average',   -- 'average' (per active officer) | 'total' | 'top10'
  minRunsActive = 3,
  weeklyBounty  = true,
  bountyBonus   = 0.10,
  bounties = {                 -- one is picked at random each week; counted per active officer
    { id = 'most_tactical',  label = 'Most Tactical missions' },
    { id = 'most_cross',     label = 'Most cross-department runs' },
    { id = 'most_unit',      label = 'Most unit runs' },
    { id = 'most_completed', label = 'Most completed runs' },
  },
}

-- ── Disputes ────────────────────────────────────────────────────────────────
Config.Disputes = { windowHours = 48 }

-- ── Mission Builder ─────────────────────────────────────────────────────────
-- Block setting ranges and defaults are in config/blocks.lua.
Config.Builder = {
  enabled           = true,
  maxHostiles       = 40,       -- armed NPCs per mission across all blocks, before scaling
  maxBlocks         = 6,
  minLocations      = 3,
  minLocationGap    = 100.0,    -- metres between locations of one mission
  minSpawnFromStart = 30.0,     -- metres between any spawn point and the start point
  bonusCap          = { points = 50, share = 0.25 },  -- flat bonuses and penalties: at most 50 points; percentage ones: at most 25% of P
  testAtMaxTier     = true,     -- publishing needs a passed test at the tier maxOfficers reaches
  editLockMinutes   = 30,       -- one editor at a time; renewed while they keep editing
  autosaveSeconds   = 30,
  exportPath        = 'missions/custom/',
  keepBackups       = true,     -- keep <mission_id>.v<version>.lua.bak on every publish
  route = {                     -- route recording (see Mission Builder, Route recording)
    snapEvery        = 25.0,    -- metres between samples while recording
    maxOffRoad       = 8.0,     -- samples further than this from a road node are rejected
    turnAngle        = 30.0,    -- heading change (degrees) that keeps a waypoint
    maxGap           = 150.0,   -- at least one waypoint this often, in metres
    minLength        = 800.0,
    maxLength        = 8000.0,
    minStartEndGap   = 300.0,   -- open routes: start and end at least this far apart
    loopClose        = 50.0,    -- a race loop must end this close to its start
    undoMetres       = 100.0,   -- Backspace removes this much of the recording
    testDriveTimeout = 30,      -- seconds to reach each waypoint in a test drive
  },
  allowed = {                   -- the only models, weapons and animations builders can pick
    weapons        = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_MICROSMG', 'WEAPON_SMG', 'WEAPON_PUMPSHOTGUN', 'WEAPON_ASSAULTRIFLE' },
    peds           = { 'g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01', 'g_m_y_lost_01', 'a_m_m_business_01', 'a_f_y_business_01' },
    vehicles       = { 'sultan', 'buffalo', 'elegy2', 'kuruma', 'dominator' },
    escortVehicles = { 'stockade', 'stockade3' },
    animations     = { 'clipboard', 'search', 'kneel', 'mechanic' },
  },
  noBuildZones = {              -- no spawn point, marker or route waypoint inside these
    { label = 'Mission Row PD and FIB HQ', coords = vec3(470.63, -974.11, 30.18),  radius = 120.0 },
    { label = 'Sandy Shores BCSO',         coords = vec3(1833.06, 3679.32, 33.19), radius = 80.0 },
    { label = 'SASP HQ',                   coords = vec3(1560.38, 815.76, 76.21),  radius = 80.0 },
    { label = 'Pillbox Hill Medical',      coords = vec3(308.19, -595.35, 43.29),  radius = 100.0 },
    { label = 'Paleto Bay Medical',        coords = vec3(-254.54, 6331.78, 32.43), radius = 80.0 },
    { label = 'Bolingbroke interior',      coords = vec3(1768.73, 2570.43, 44.73), radius = 180.0 },  -- widen or move to fit your prison
  },
}

-- ── Admin test mode ─────────────────────────────────────────────────────────
Config.Testing = {
  enabled       = true,
  maxTesters    = 8,       -- players in one test run, including the admin
  useStartRoute = false,   -- default for the start-route toggle
  allowTeleport = true,    -- teleport controls in test runs
  debugOverlay  = true,    -- the debug overlay control
}

-- ── Retention ───────────────────────────────────────────────────────────────
Config.Retention = {
  runArchiveMonths = 12,    -- move older runs to cp_mission_runs_archive; 0 = never
  auditDays        = 180,   -- delete older audit rows; 0 = keep forever
}

-- Discord webhooks are read from convars in server.cfg, never stored here.
-- A convar that is missing or empty turns that webhook off.
--   set cp_webhook_board      "https://discord.com/api/webhooks/..."   (weekly top 3, season results)
--   set cp_webhook_audit      "https://discord.com/api/webhooks/..."   (payout changes and admin actions)
--   set cp_webhook_flags      "https://discord.com/api/webhooks/..."   (flagged runs, voids, disputes)
--   set cp_webhook_builder    "https://discord.com/api/webhooks/..."   (publish, archive, rollback, lock breaks, code edits)
--   set cp_webhook_operations "https://discord.com/api/webhooks/..."   (Cross-Department launches and results)

config/blocks.lua holds the range and default of every Mission Builder setting, so a server owner can widen or narrow what builders may pick without touching code. It follows the Mission Builder tables exactly:

-- config/blocks.lua · Mission Builder ranges and defaults.
-- Numbers are { min, max, default }; the tablet only accepts values in range,
-- and the server checks them again on publish and on /CrimsonPoliceAdmin reload.
-- Times are seconds, distances metres, speeds km/h, chances percent. When the builder
-- writes a mission file it converts chances to fractions (30 → 0.30) and progress
-- times to milliseconds (5 → 5000), the units mission files use.
Config.Blocks = {
  details = {                     -- the Details step, for every mission
    difficulty   = { 1, 3, 2 },   -- stars
    officers     = { 1, 4 },      -- min and max officers the builder may set
    timeLimit    = { 120, 1200, 600 },
    startTimeout = { 300, 900, 600 },
    cooldown     = { 300, 3600, 1200 },
    vehiclePenalties = { default = true },  -- false turns off the heavy vehicle-damage penalty
  },

  hostile_waves = {
    waves         = { 1, 6, 3 },
    perWave       = { 1, 15, 7 },          -- every armed NPC in the mission together: at most Config.Builder.maxHostiles
    nextWaveAlive = { 0, 5, 2 },           -- next wave when this many or fewer are alive...
    nextWaveAfter = { 30, 300, 90 },       -- ...or after this long
    weapons       = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG' },   -- default pick from Config.Builder.allowed.weapons
    accuracy      = { 5, 60, 25 },
    armour        = { 0, 100, 0 },
    health        = { 100, 400, 200 },     -- also the range for the boss
    behaviour     = { options = { 'hold', 'balanced', 'push' }, default = 'balanced' },
    surrender     = { 0, 100, 30 },        -- chance to surrender under 25% health
    peds          = { 'g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01', 'g_m_y_lost_01' },
    boss          = { default = false },   -- when on: model, health, armour and weapon from the ranges above
    blockTraffic  = { 0, 200, 120 },
    spawnPointsPerHostile = 1.5,           -- spawn points needed per hostile in the largest wave
    presenceRange = { 50, 800, 150 },      -- from the nearest living hostile
  },

  escort = {
    vehicle      = 'stockade',             -- default pick from Config.Builder.allowed.escortVehicles
    speed        = { 20, 120, 60 },
    style        = { options = { 'careful', 'normal', 'fast' }, default = 'normal' },  -- always lane-following
    toughness    = { 0.5, 3.0, 1.5 },      -- × vehicle health
    stoppedFail  = { 15, 120, 60 },
    arrival      = { 10, 50, 20 },
    stops        = { 0, 5, 0 },            -- stop points added with E while recording
    stopWait     = { 10, 60, 20 },         -- seconds at each stop; never counts toward stoppedFail
    ambushPoints = { 1, 10, 5 },
    ambushGap    = 150.0,                  -- minimum metres between ambush points
    ambushWaves  = { 1, 5, 2 },
    carsPerWave  = { 1, 5, 2 },
    perCar       = { 1, 4, 2 },            -- attackers per car; weapons, accuracy and armour as hostile_waves
    presenceRange = { 50, 800, 300 },      -- from the escorted vehicle
  },

  pursuit = {
    mode         = { options = { 'follow', 'stop' }, default = 'stop' },
    vehicles     = { 1, 5, 1 },
    route        = { options = { 'free', 'recorded' }, default = 'free' },
    speed        = { 40, 160, 120 },
    style        = { options = { 'cautious', 'reckless' }, default = 'reckless' },
    suspects     = { 1, 4, 1 },            -- per vehicle
    footFlee     = { 0, 100, 20 },         -- chance to flee on foot after the stop
    holdDistance = { 50, 300, 150 },       -- Follow mode
    lostDistance = { 150, 600, 250 },
    lostSeconds  = { 5, 30, 10 },
    duration     = { 60, 600, 180 },
    presenceRange = { 50, 800, 400 },      -- from the nearest suspect vehicle, or suspect on foot
  },

  checkpoint_route = {
    checkpoints    = { 2, 20 },
    use            = { options = { 'all', 'random' }, default = 'all' },
    radius         = { 3, 20, 10 },
    stopFor        = { 0, 30, 10 },
    policeVehicle  = { default = true },   -- uses Config.PoliceVehicles
    medals         = { default = false },  -- when on: Gold, Silver and Bronze times in seconds
    contactPenalty = { 0, 10, 2 },         -- seconds added per hit
    presenceRange  = { 50, 800, 300 },     -- from the next checkpoint or the nearest partner, whichever is closer
  },

  interact_points = {
    points     = { 1, 10 },
    use        = { options = { 'all', 'random' }, default = 'all' },
    progress   = { 1, 30, 5 },
    label      = 'Checking…',
    animation  = 'clipboard',              -- default pick from Config.Builder.allowed.animations
    logResult  = { default = false },
    logChoices = { 2, 4, 2 },
    presenceRange = { 50, 800, 150 },   -- from the nearest point not yet done
  },

  skill_check = {
    checks      = { 1, 8, 4 },
    difficulty  = { options = { 'easy', 'medium', 'hard' }, default = { 'easy', 'medium', 'medium', 'hard' } },
    missPenalty = { 0, 120, 30 },          -- seconds off the timer
    failAfter   = { 1, 3, 2 },             -- misses in a row
    presenceRange = { 50, 800, 150 },      -- from the device or point being worked on
  },

  protect_rescue = {
    npcs       = { 1, 6, 3 },
    peds       = { 'a_m_m_business_01', 'a_f_y_business_01' },
    restrained = { default = true },
    freeTime   = { 1, 15, 6 },
    hitPenalty = { 0, 100, 50 },
    failIfDies = { default = true },
    presenceRange = { 50, 800, 150 },   -- from the nearest NPC being protected
  },

  flee_arrest = {
    suspects       = { 1, 10, 1 },
    responses      = { surrender = 50, flee = 30, fight = 20 },   -- must add up to 100
    armedChance    = { 0, 100, 20 },
    weapons        = { 'WEAPON_PISTOL' },
    escapeDistance = { 200, 800, 400 },
    escapeSeconds  = { 10, 60, 20 },
    givesUp        = { options = { 'aim', 'stun', 'close' }, default = { 'aim', 'stun', 'close' } },
    aimDistance    = { 5, 15, 10 },        -- gives up when aimed at within this distance,
    closeDistance  = 3.0,                  -- ...or when a participant stays this close...
    closeSeconds   = 3,                    -- ...for this long (or when stunned)
    presenceRange  = { 50, 800, 250 },     -- from the nearest suspect not yet cuffed
  },

  search_area = {
    startRadius = { 200, 1000, 600 },
    clues       = { 1, 5, 3 },
    shrinkTo    = { 300, 150, 50 },        -- circle radius after each clue
    fugitives   = { 1, 5, 1 },
    runDistance = { 10, 60, 30 },
    presenceRange = { 50, 800, 100 },      -- margin outside the current search circle (inside always counts)
  },
}

## Example files

Copy these shapes exactly. Every mission file, built-in or custom, contains one RegisterMission({ ... }) call; the coordinates below are placeholders.

Built-in mission: missions/builtin/gang_shootout.lua

RegisterMission({
  id           = 'gang_shootout',
  label        = 'Gang Shootout',
  description  = 'Armed gang members are holed up at a remote hideout. Clear it and secure the scene.',
  type         = 'tactical',     -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 600,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 1200,           -- per officer, seconds
  vehiclePenalties = false,      -- gunfire damages vehicles here, so no heavy-damage penalty

  locations = {
    {
      label  = 'Hideout A',
      start  = { coords = vec3(0.0, 0.0, 0.0), radius = 80.0 },   -- placeholder
      spawns = { vec4(0.0, 0.0, 0.0, 0.0) },                      -- 12+ hostile spawn points
      scene  = vec3(0.0, 0.0, 0.0),                               -- "Secure the scene" point
    },
    -- ...at least 5 locations
  },

  objectives = {
    {
      block        = 'hostile_waves',
      label        = 'Neutralise all hostiles',
      minSeconds   = 60,                                       -- quicker than this is rejected
      waves        = { 7, 7, 6 },                              -- base counts, scaled by tier
      nextWave     = { aliveAtMost = 2, afterSeconds = 90 },
      weapons      = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG' },
      accuracy     = 25,                                       -- plus the tier's accuracy
      armour       = 0,                                        -- plus the tier's armour
      surrender    = { belowHealth = 0.25, chance = 0.30 },
      blockTraffic = 120.0,
    },
    {
      block      = 'interact_points',
      label      = 'Secure the scene',
      minSeconds = 8,
      points     = 'scene',
      progress   = { label = 'Securing scene', duration = 8000 },
    },
  },

  scaling   = { 'objectives.1.waves' },    -- counts multiplied by the tier
  items     = {},                          -- no items for this mission
  bonuses   = {
    { id = 'no_participant_downed', pctOfPoints = 0.10 },
    { id = 'hostile_arrested', points = 5, each = true },
  },
  penalties = {},                          -- the common penalties always apply
})

Custom mission exported by the Mission Builder: missions/custom/custom_dockside_raid.lua

--[[ Crimson-Police · custom mission (written by the Mission Builder)
  id:        custom_dockside_raid
  version:   3
  type:      tactical   -- the payout comes from the Payouts screens, never from this file
  published: 2026-09-28 05:40 by Sgt. J. Doe (SAST, citizenid ABC12345)
  Edit this file, then run: /CrimsonPoliceAdmin reload
]]

RegisterMission({
  id           = 'custom_dockside_raid',
  label        = 'Dockside Raid',
  description  = 'A smuggling crew is unloading at the docks. Clear the dock and seize the shipment.',
  type         = 'tactical',
  departments  = {},             -- empty = every department
  minOfficers  = 2,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 720,
  vehiclePenalties = false,
  startTimeout = 600,
  cooldown     = 1200,

  locations = {
    {
      label    = 'Dock 1',
      start    = { coords = vec3(0.0, 0.0, 0.0), radius = 60.0 },
      spawns   = { vec4(0.0, 0.0, 0.0, 0.0) },
      evidence = { vec3(0.0, 0.0, 0.0) },
    },
    -- ...at least 3 locations
  },

  objectives = {
    { block = 'hostile_waves', label = 'Clear the dock', minSeconds = 45, waves = { 6, 6 },
      weapons = { 'WEAPON_PISTOL', 'WEAPON_SMG' }, accuracy = 30, armour = 10 },
    { block = 'interact_points', label = 'Seize the shipment', minSeconds = 6, points = 'evidence',
      progress = { label = 'Seizing crates', duration = 6000 } },
  },

  scaling   = { 'objectives.1.waves' },
  items     = {},
  bonuses   = { { id = 'no_participant_downed', pctOfPoints = 0.10 } },
  penalties = {},
})

## Anti-exploit & fairness

No client message can award points or cash directly. The server re-checks every objective and flags anything that looks impossible.

| Risk | Control |
|---|---|
| Triggering objective events from an executor | Events need a valid runId owned by the sender; each objective is accepted once and in order; unexpected events flag the run and are logged |
| Teleporting or impossible speed | The server compares coordinates between objective events; travel faster than Config.AntiCheat.maxSpeed (80 m/s) flags the run |
| Completing too fast | Each objective has a minimum time (minSeconds in the mission file, or the block's default); anything quicker is rejected |
| Repeating a favourite mission | Officers can only pick a type; the server draws the mission and skips their last one(s) in that type |
| Rerolling by abandoning, leaving the start route or not driving to the start | All three end the run as Abandoned and put the whole type on cooldown |
| Faking start-route reports | A missing report for 10 seconds counts as off route, and the server runs its own drift check (1,000 m) whatever the client reports |
| Going down on purpose to escape a bad draw | Downed is Failed, with the type cooldown |
| Using a real call to dodge a failing run | Un-marking responding within 60 seconds turns the free abandon into a normal one (type cooldown, end_reason = 'real_call_cancelled') |
| Faking a responding event for a free abandon | Only a call that exists and is active in SC-Dispatch's mdt_dispatch table counts; anything else is ignored |
| Farming the same route | Random missions and locations, per-mission cooldowns, hourly cap |
| Two runs on the same spot, or too many runs at once | Locations in use are reserved; at most 12 runs are active at once, 4 of them Tactical (Config.Limits) |
| Joining a unit or operation only for the multiplier or cash | In runs with 2 or more participants, each participant must stay within the current objective's presence range (150 m by default, 300 m around an escorted vehicle, 400 m in pursuits; see Presence range below) for 70% of the run to get points or cash; anyone who doesn't keeps the run's result with 0 points and $0, and their row is flagged for review |
| Inflating the tier with idle participants | 3 minutes after the run moves to In progress, anyone who has not reached the start (the same arrival check the start route uses) is removed as Abandoned (idle) and the tier is recalculated; it can only go down |
| Off-duty, suspended or non-police players | Active job, duty, Crimson-Police suspension and SC-Dispatch suspension are checked on accept, on join and on every objective |
| Switching job mid-run with sc-multijob | That participant is Abandoned (type cooldown applies); the run continues for the rest |
| Staying on a mission during a real call | Responding to, or being assigned, a real call ends the run automatically; supervisors can also force recall |
| Payout changed mid-run | The base payout is locked at accept; the tier is set at the start and can only go down |
| Supervisor payout abuse | Only 50–200% of the type's config payout, at most once per 30 minutes per type, with a reason; every change is audited and posted to the audit webhook; admin-set types are locked |
| Reviewing your own runs | Your own runs never appear in your Review Queue, and the server refuses any approval, void or dispute answer by a participant of that run |
| Easy custom missions built to farm | Allowed lists, minimum objective times, bonus caps, a passed test at the tier maxOfficers reaches before publishing, and neutral star multipliers by default; every publish is posted to the builder webhook, and admins can archive or roll back |
| Double cash payments | One payment per participant per run: the row is claimed (paying) before any money moves, and a row with a final status is never paid again, and the Renewed-Banking entry carries the transaction id CP-<run_uuid>-<citizenid> |
| Hand-editing a payout into an exported Lua file | Ignored, with a console warning; payouts only come from the Payouts screens |
| Disconnect abuse | A disconnected participant is Failed (partial points, no cash) and gets the type cooldown, so disconnecting is never a free reroll; the run continues for anyone left |
| Friends or bystanders clearing a mission for you | When a mission NPC dies, the server checks who killed it (GetPedSourceOfDeath, or the driver of the vehicle that did it). A kill by a player who isn't on the run flags the run for review (flag_reason = 'outside_help'), holding its points and cash; the Review Queue shows who it was. The number of outside kills that flags a run is Config.AntiCheat.outsideKillsToFlag |
| Using test runs to farm | Only admins can start them, and nothing in a test run is saved or paid |
| Boosting the tier with friends who then leave | The NPCs still to come shrink, and leaving by choice, disconnecting or never arriving also drops the points and cash tier to the team that's left. Only a real call, a force recall or going down keeps it (Config.Rescale.keepPayTierFor) |

Presence range (runs with 2 or more participants)

Each participant must stay within the current objective's presence range for 70% of the run (Config.AntiCheat.presenceShare). The range depends on the block, because chases and escorts spread officers out:

| Block | Measured from | Default range |
|---|---|---|
| hostile_waves | The nearest living hostile, or the location's start point between waves | 150 m |
| interact_points | The nearest point not yet done | 150 m |
| skill_check | The device or point being worked on | 150 m |
| protect_rescue | The nearest NPC being protected | 150 m |
| flee_arrest | The nearest suspect not yet cuffed | 250 m |
| escort | The escorted vehicle | 300 m |
| pursuit | The nearest suspect vehicle, or suspect on foot | 400 m |
| checkpoint_route | The next checkpoint or the nearest other participant, whichever is closer | 300 m |
| search_area | The edge of the current search circle (anywhere inside always counts) | 100 m |

A mission can give any objective its own presenceRange, and the Mission Builder sets it per block (50–800 m). The defaults live in config/blocks.lua; Config.AntiCheat.presenceRadius (150 m) is used only for a block without one.

Flagged runs are held off the leaderboards, and their cash is held, until a supervisor approves or voids them, and each one records why it was flagged (flag_reason). Three voided runs in 30 days suspends that officer from Crimson-Police for 7 days (all three numbers are in Config.AntiCheat).

## Supervisor & admin actions

Supervisors work from the Supervisor UI and admins from the Admin UI. Admins can always do every action marked Admin below. Config.Permissions.supervisor switches the supervisor actions on or off; by default all are on except rolling back missions, breaking edit locks and editing other people's missions. Nobody can approve, void or answer a dispute about a run they took part in. Actions that list a /CrimsonPoliceAdmin subcommand can also be run from the server console.

| Action | Who | Where | What it does |
|---|---|---|---|
| Open the Admin UI | Admin | /CrimsonPoliceAdmin (no arguments) | Opens the Admin UI |
| Set a mission type's payout | Supervisor (unless admin-set; 50–200% of the config payout, at most once per 30 minutes per type, reason required), Admin | Supervisor UI or Admin UI → Payouts; /CrimsonPoliceAdmin payout type <type> <amount|clear> <reason> | Base payout for every mission of that type; an admin-set value is permanent and read-only for supervisors |
| Set or clear one mission's payout | Admin only | Admin UI → Payouts; /CrimsonPoliceAdmin payout mission <missionId> <amount|clear> <reason> | Permanent base payout for that mission, overriding its type |
| Launch, start, relaunch or cancel a Cross-Department Mission | Supervisor, Admin | Supervisor UI → Mission List and Cross-Department Mission; Admin UI → Missions | Locks every department's board to one mission until it is completed or cancelled; at most one launch every 30 minutes |
| Force recall | Supervisor | Supervisor UI → Live Missions | Ends one officer's run as Abandoned, with no cooldown and no penalty |
| Approve or void a flagged run | Supervisor (runs involving their department, never their own), Admin | Supervisor UI → Review Queue; Admin UI → Leaderboards | Releases or removes the points and held cash; reason required |
| Void any run | Admin | Admin UI → Leaderboards | Removes a run from every board; reason required |
| Handle a dispute | Supervisor (flagged or voided runs in their department, never their own), Admin (failed runs) | Supervisor UI → Review Queue; Admin UI → Officers | Approve (restore the run and release held cash, or make a manual award for a failed run) or reject; reason required |
| Manual award | Admin | Admin UI → Leaderboards; /CrimsonPoliceAdmin award <citizenid> <points> <reason> | Manual points, stored as a 'manual_award' row |
| Start or end a season | Admin | Admin UI → Seasons & Challenge; /CrimsonPoliceAdmin season start <name> or season end | Opens or closes a season and its department challenge |
| Override this week's bounty | Admin | Admin UI → Seasons & Challenge | Replaces the randomly picked bounty for the current week |
| Suspend or unsuspend an officer | Admin | Admin UI → Officers; /CrimsonPoliceAdmin suspend <citizenid> <days> | Blocks an officer from Crimson-Police for that many days; 0 days lifts it |
| Publish a tested draft | Supervisor (own missions; any mission with builderEditAny), Admin | Supervisor UI → Mission Builder; Admin UI → Missions | Makes the draft the live version and writes its Lua file |
| Archive or restore a custom mission | Supervisor (own missions; any mission with builderEditAny), Admin | Supervisor UI → Mission Builder; Admin UI → Missions | Removes a custom mission from its pool, or puts it back |
| Roll back a custom mission | Admin (supervisors only with builderRollback) | Admin UI → Missions; Supervisor UI → Mission Builder when allowed | Restores the previous version from its .bak file as a new version |
| Break an edit lock | Admin (supervisors only with breakEditLock) | Admin UI → Missions; Supervisor UI → Mission Builder when allowed | Unlocks a mission someone else is editing; their changes since the last autosave are lost |
| Reload mission files | Admin | Admin UI → Missions; /CrimsonPoliceAdmin reload | Reloads built-in and custom mission files without a restart |
| Start a test run | Admin | Admin UI → Testing; /CrimsonPoliceAdmin test <missionId> [tier] [location] | Starts any mission at the chosen location and tier; nothing is saved or paid (see Admin test mode) |

Every action is written to cp_audit (who, role, action, target, old and new value, reason, time) and posted to its webhook: payout changes and admin actions to cp_webhook_audit, flagged runs, voids and disputes to cp_webhook_flags, Mission Builder actions to cp_webhook_builder, and Cross-Department Missions to cp_webhook_operations (see Config).

## Admin test mode

Admins can start any mission on demand, pick its location and tier, and play or step through it to check that it works. Nothing in a test run is saved or paid. The Mission Builder's test run of a draft uses the same mode.

Starting a test: Admin UI → Testing, or /CrimsonPoliceAdmin test <missionId> [tier] [location] in game.

- Any mission can be tested: built-in, custom (published or archived), or turned off in Config.DisabledMissions. Drafts are tested from the Mission Builder.

- The admin picks the location (one of the mission's numbered locations, or Random) and the tier (Standard to Critical), whatever the number of testers.

- The start route is off by default, so the admin can teleport straight to the start; switch it on to test the route rules too.

- The admin can invite up to 7 more testers (on-duty officers or admins), who accept on their own screen, to test a mission with a full unit.

How a test run differs from a real run

- Nothing is saved or paid: no cp_mission_runs row, no points, XP, cash, goals, streaks or badges, and nothing reaches the leaderboards or the department challenge.

- The result screen still shows the points and cash the run would have earned, so the formulas can be checked.

- Cooldowns, the hourly cap, the server run caps and the Cross-Department lock never block a test run, and a test run starts no cooldown. It still reserves its location, so no live run is drawn on top of it.

- Everything else works exactly as in a real run: scaling, NPCs, objectives, alert suppression, real calls, downed handling and cleanup.

- Every tester's HUD shows a "TEST RUN" banner.

Test controls (on the HUD, only for the admin who started the test)

| Control | What it does |
|---|---|
| Skip objective | Marks the current objective done and starts the next one |
| Restart objective | Removes and respawns the current objective's NPCs, vehicles and props |
| Pause timer | Stops or restarts the mission timer |
| Force complete / Force fail | Ends the test with that result, to check the result screen |
| Debug overlay | Shows spawn points, zones, route waypoints and the start radius, plus live NPC and entity counts against the caps |
| Teleport | Moves the admin to the start or to the current objective |
| End test | Ends the test and cleans everything up |

Running through the catalog: Admin UI → Testing lists every mission and each of its locations with its last test result (Passed, Failed or Not tested), the tier, who tested it and when. After each test the admin marks it Passed or Failed, with an optional note such as "spawn 3 is inside a wall". Results are saved in cp_mission_tests and posted to the builder webhook. A mission edited, re-published or reloaded since its last test shows "Changed since test", so staff can see what still needs checking before go-live.

Every test start is written to the audit log. The options are in Config.Testing.

## SOP: rules of use for officers

Crimson-Police is a downtime activity. Real calls and real players always come first, and misuse is handled like any other SOP violation.

- Real RP first. When dispatch or a supervisor calls for units, respond at once. Marking yourself responding in SC-Dispatch, or being assigned by a dispatcher, ends your mission automatically with no penalty. Staying on a mission during a priority call is a violation.

- Stay available. Keep your radio on the patrol channel and your SC-Dispatch status accurate while on a mission. Never mark responding just to escape a mission that is going badly; un-marking within 60 seconds counts as a normal abandon.

- Follow the route to the start. Drive the route the tablet sets; leaving it ends your run.

- No farming. Do not repeat missions to climb the board or earn cash, and do not share or use exploits. Report bugs to command instead.

- Units are real units. Only team up with officers, from any department, who are actually working the mission with you. Joining only for the multiplier or cash voids the run.

- Drive and act in character. Mission driving follows normal pursuit and code 3 policy; reckless driving to finish faster is subject to discipline.

- Civilians are not mission targets. Never stop, detain or involve a real player to complete a mission objective.

- Mission combat stays off the radio. Don't press your panic button or call for backup over mission NPCs; missions never need real units. If you go down while EMS is on duty, the EMS request is sent for you.

- Don't go down on purpose. Going down fails your run and puts the type on cooldown.

- Cross-Department Missions are joint operations. Follow the launching supervisor's lead, and leave the operation to answer real calls.

- Disputes use Dispute on a flagged, voided or failed run in Profile & History within 48 hours. Disputes about flagged or voided runs go to your department's supervisors, and disputes about failed runs (for example a bug) go to admins. Nobody reviews their own runs, and their decision is final.

Discipline ladder: verbal warning → run voided (points removed, held cash not paid) → 7-day Crimson-Police suspension → removal from the system and a standard write-up.

## Performance, testing & acceptance

The release is accepted when every check below passes on a test server with at least 10 officers from both departments. Checks about seasons, boards other than Weekly, goals, special events and the Mission Builder belong to Phases 3 and 4 and are run when those phases ship.

Performance targets

- Client resmon at most 0.02 ms idle and 0.10 ms during a run (no per-frame loops outside active objectives).

- Server resmon at most 0.25 ms with 30 officers online and a Critical-tier Cross-Department Mission running; leaderboard queries under 50 ms.

- The Officer UI opens in under 300 ms, and no entity is left behind after any run ends.

Acceptance checks

- ☐ Any on-duty SAST or FIB officer can open /CrimsonPolice and start a mission at any time; off-duty, suspended and non-department players cannot

- ☐ Only the active job counts: holding sast as a second sc-multijob job gives no access

- ☐ Qbox only: qb-core is not a dependency, and a search of the code finds no GetCoreObject or QBCore.Functions

- ☐ The header shows the department name and tag, the rank (Qbox job grade name) and the callsign; a callsign changed with SC-Police's /callsign shows the next time the tablet opens

- ☐ Every screen, the mission HUD and all notifications are Crimson-Police's own NUI; ox_lib only appears as the progress bar and skill check during missions

- ☐ Adding BCSO to Config.Departments with its own colours and logos/bcso.png shows BCSO's name, colours and watermark to BCSO officers, and adds BCSO to the boards, the challenge, unit invites and the builder, with no code or SQL changes

- ☐ The watermark sits behind all content, never blocks clicks, and a missing logo shows no broken image

- ☐ Officers can only accept a mission type; the drawn mission is random and never their last one in that type unless it is the only eligible one

- ☐ Abandoning, leaving the start route or not reaching the start within the start timeout puts the whole type on cooldown

- ☐ More than 120 m off the start route warns after 10 seconds and ends that participant's run as Abandoned after 30; getting back on the route resets the timer; Recalculate route works twice per run; stopping route reports counts as off route

- ☐ Being assigned to, or marking responding to, a real SC-Dispatch call ends that participant's run at once as Abandoned with no cooldown while the rest of the unit carries on; SC-NPCPolice calls (npccall-…) never end a run; un-marking within 60 seconds applies the type cooldown; a partner's person-down call never ends the other partners' runs; a faked call id does nothing; an officer responding to a real call can't accept a mission

- ☐ Mission gunfire by participants who have reached the start creates no SC-Dispatch shots-fired call and no SC-Ambulance person-down alert; a shots-fired, person-down or dead call forced through while the flag is on is cleared within 3 seconds; the flag is removed when the run ends (a downed participant keeps it until the pick-up or the EMS request), and a flag another resource set is never removed

- ☐ A participant who goes down Fails with the type cooldown; with no EMS on duty they are revived and moved to the nearest drop-off after 15 seconds, with no bill; with EMS on duty an EMS request is sent for them; hospital:server:RevivePlayer is never triggered

- ☐ Two runs never use the same location at once; with 12 runs active (or 4 Tactical) new accepts are refused and the cards show "Server busy"

- ☐ SAST and FIB officers can form one unit; invites close when the leader accepts a type, and the unit's runs earn the cross-department points bonus

- ☐ A run's tier matches its participant count at the start and changes hostile numbers, accuracy, armour, points and cash as in the scaling table; waves respect the 25-alive and 80-entity caps without cutting counts

- ☐ Every participant sees the same NPCs; if the run host leaves, the next participant takes over the NPC AI; NPCs never drop weapons

- ☐ Launching a Cross-Department Mission hides every other mission for every department and the server refuses other accepts; the lock lifts only when it is completed or cancelled; it auto-cancels after 30 idle minutes; a new one can't be launched within 30 minutes of the last

- ☐ Supervisors can play missions like officers and see the full Mission List; officers never see individual missions

- ☐ Officer, Supervisor and Admin UIs each show only their own screens, and the server rejects supervisor or admin actions from anyone without the role; a supervisor action switched off in Config.Permissions is hidden and refused

- ☐ Supervisors can change a type's payout only when no admin has set it, only within 50–200% of its config payout, at most once per 30 minutes per type and with a reason; admin-set type and mission payouts survive restarts, season resets, re-publishes and reloads until an admin changes or clears them

- ☐ Nobody can approve, void or answer a dispute about a run they took part in

- ☐ Completed runs pay each participant base payout × tier × modifier into the bank with a Renewed-Banking entry; Failed and Abandoned results pay nothing

- ☐ No payment is ever made twice for the same participant and run; with the society source, an empty department account pays $0 and marks the run unfunded; held cash approved while the officer is offline is paid when they next load in

- ☐ Daily and weekly goals award their points once when completed; with Config.Time.resetHour = 6, Type of the Day, daily goals and the daily cash cap reset at 06:00

- ☐ A dispute about a flagged or voided run reaches the department's supervisors, a dispute about a failed run reaches admins, and each can be approved or rejected

- ☐ Mission items are given and removed through ox_inventory correctly

- ☐ Forged or too-fast objective events are rejected and flag the run, and flagged runs hold their cash until approved

- ☐ The weekly board resets on Monday at the reset hour (00:00 by default) and posts the top 3 to Discord; each webhook convar posts only its own category, and an empty one posts nothing

- ☐ The department challenge score matches the configured scoring mode, and the weekly bounty is applied once

- ☐ A Mission Builder mission can be drafted, test-run, published into its type's pool and completed without a restart

- ☐ A route recorded at any speed is saved as road waypoints; the NPC vehicle drives those roads at the set speed and style, in its lane, not the builder's exact line; off-road samples are rejected; a route outside 0.8–8 km or through a no-build zone can't be saved; Test drive marks unreachable waypoints

- ☐ The builder only offers models, weapons, vehicles and animations from Config.Builder.allowed and values inside config/blocks.lua; spots inside no-build zones, within 30 m of the start, or locations under 100 m apart are refused; publishing needs a passed test at the tier maxOfficers reaches

- ☐ Only one person can edit a mission at a time; drafts autosave every 30 seconds; the published version stays live while a draft is edited; an admin can break an edit lock and roll back to the previous version

- ☐ Publishing writes missions/custom/<mission_id>.lua; editing it and running /CrimsonPoliceAdmin reload loads it as a new version, and a hand-added payout field is ignored

- ☐ Voided runs disappear from every board within 60 seconds

- ☐ A participant who disconnects is cleaned up and gets the type cooldown, and the run continues for the rest of the unit

- ☐ Stopping the resource mid-run removes every mission entity and alert flag, and nobody gets a cooldown for those runs

- ☐ All 13 missions and the Weekly Boss complete end-to-end at every tier they support, with correct points and cash breakdowns

- ☐ An admin can start any mission (built-in, custom, archived or turned off) at any location and tier from Admin UI → Testing or /CrimsonPoliceAdmin test; the test saves and pays nothing, starts no cooldown, ignores the caps and the Cross-Department lock, still reserves its location, and shows the points and cash it would have earned

- ☐ The test controls work (skip and restart objective, pause timer, force complete or fail, debug overlay, teleport, end test), and only the admin who started the test sees them

- ☐ Admin UI → Testing shows every mission and location with its last result, and a mission changed since its last test shows "Changed since test"

- ☐ A mission NPC killed by a player who isn't on the run flags the run for review with flag_reason = 'outside_help'

- ☐ A fresh database is built by 001_initial.sql; a new 002_ file is applied once on the next start; a failing migration stops the resource with a clear error; no migration drops a table or deletes history

- ☐ When a partner leaves mid-run, waves not yet spawned shrink to the team that's left; the points and cash tier stays for a real call, force recall or downed partner and drops for any other reason

- ☐ In a unit, a partner up to 400 m from the suspect vehicle in a pursuit, or 300 m from an escorted truck, still counts as present

- ☐ Missing one day in a week keeps an officer's streak (that day adds nothing); a second missed day that week resets it

- ☐ Missions with vehiclePenalties = false (Stolen Vehicle Takedown, Street Race Bust and the others listed in Scoring) never apply the heavy-damage penalty, while their ramming penalties still apply

## Build order

Build in this order. Each step names the folders it touches and the check that proves it is done; do not start a step until the previous step's check passes.

Phase 1 · Core

| Step | Folders and files | Done when |
|---|---|---|
| 1. Resource skeleton | fxmanifest.lua, config/, shared/, locales/en.json, sql/migrations/, modules/migrations/ | The resource starts with no errors, creates every table through sql/migrations/001_initial.sql, and a second start applies nothing |
| 2. Integrations | modules/integrations/qbx/, sc_dispatch/, sc_ambulance/, renewed_banking/ | Each wrapper returns correct data for a test player: job, rank, callsign, duty, suspension, responding status, call lookup, EMS on duty, bank entry |
| 3. Access, roles and permissions | modules/access/, modules/permissions/ | The server identifies an on-duty SAST officer, an FIB supervisor and an admin correctly, refuses off-duty, suspended and second-job players, and refuses a supervisor action switched off in Config.Permissions |
| 4. Officer UI and theming | modules/tablet/, web/src/officer/, web/src/hud/, web/src/shared/, logos/ | /CrimsonPolice opens a tablet titled Crimson-Police with the officer's department name, rank, callsign, colours and watermark; an FIB officer sees FIB's |
| 5. Draw and run lifecycle | modules/draw/, modules/runs/, modules/schedule/ | Accepting a type draws a random eligible mission and reserves its location; start timeout, abandon, type cooldown, the server run caps and end reasons behave as specified; the server creates and deletes the mission's entities |
| 6. Route to the start | modules/route/ | Leaving the route warns at 10 seconds and abandons at 30 with the type cooldown; Recalculate works twice; missing reports and the drift check behave as specified |
| 7. Real calls and alert suppression | modules/calls/, modules/alerts/ | A real call ends the run with no cooldown, an NPC call does not, and the 60-second rule applies; test gunfire during a run creates no shots-fired call, and one forced through is cleared |
| 8. Downed participants | modules/downed/ | Going down is Failed with the type cooldown; with no EMS on duty the officer is picked up after 15 seconds; with EMS on duty the EMS request is sent |
| 9. First blocks and missions | modules/testing/, blocks/checkpoint_route/, blocks/interact_points/, missions/builtin/beat_patrol.lua, business_check.lua, evoc_course.lua | Beat Patrol, Business Check and EVOC Course complete end-to-end, and /CrimsonPoliceAdmin test starts each of them at any tier and location with working test controls |
| 10. Objective validation | modules/anticheat/ | Forged or too-fast objective events are rejected and flag the run |
| 11. Points | modules/scoring/ | Breakdowns match the points formula for solo runs |
| 12. Cash | modules/cash/ | Completed runs pay the config default payouts into the bank with a Renewed-Banking entry, and never twice |
| 13. Weekly leaderboard | modules/leaderboard/ | The top 25 show with the viewer's row pinned, and the board resets on Monday |

Phase 2 · Teams and full catalog

| Step | Folders and files | Done when |
|---|---|---|
| 14. Units | modules/units/ | SAST and FIB officers form a unit of up to 4, invites close at accept, and every member shares one drawn mission and the same NPCs |
| 15. Scaling | modules/scaling/ | Tier, counts, accuracy, armour, points and cash match the scaling table for 1–4 participants |
| 16. Remaining blocks and missions | the other 7 blocks/<block_id>/ folders and 10 missions/builtin/ files | All 13 missions complete at every tier they support |
| 17. Supervisor UI, Admin UI, payouts and disputes | web/src/supervisor/, web/src/admin/, modules/admin/, modules/payouts/, modules/disputes/ | Each UI shows only its own screens; payout edits follow the supervisor limits and admin rules; nobody can review their own runs; flagged runs and disputes can be reviewed; every /CrimsonPoliceAdmin subcommand works; each webhook posts its own category; Admin UI → Testing lists every mission and location with its last test result |
| 18. Cross-Department Missions | modules/operations/ | Launch locks every board; join, start, fail-relaunch, cancel, idle auto-cancel and the 30-minute launch cooldown work with up to 8 participants |

Phase 3 · Seasons and events

| Step | Folders and files | Done when |
|---|---|---|
| 19. Monthly, season and department boards; badges; goals | modules/leaderboard/, modules/scoring/, modules/goals/ | Boards, filters, badges and goals match the spec, and daily things reset at Config.Time.resetHour |
| 20. Department challenge | modules/challenge/ | Scores, bounties and winners match the configured mode |
| 21. Special events | modules/events/, missions/builtin/weekly_boss_kingpin.lua | Type of the Day, modifiers and the Weekly Boss behave as specified |

Phase 4 · Mission Builder

| Step | Folders and files | Done when |
|---|---|---|
| 22. Builder UI, block settings and placement tool | modules/builder/, config/blocks.lua, web/src/supervisor/, web/src/admin/ | A mission can be drafted with every block's settings (only in-range values and allowed models) and placed in-game; no-build zones and spacing rules are enforced |
| 23. Route recording and test drive | modules/builder/ | A route recorded at any speed is saved as road waypoints; the test drive follows those roads in lane at the set speed; the route checks refuse bad routes |
| 24. Test, publish, versions, locks and Lua export | modules/builder/ | Publishing needs a passed test at the tier maxOfficers reaches and writes the Lua file; edit locks, autosave and rollback work; /CrimsonPoliceAdmin reload picks up a hand edit as a new version |

Go live after Phase 2, when units, the full catalog and the Supervisor and Admin UIs (needed to review flagged runs) are in. Steps 6–8 enforce Hard rules 15–18, so they are never skipped or postponed. Phases 3 and 4 ship once the live server has run for 2 weeks with fewer than 2 disputes a week, their checks pass and command staff sign off.

## Server owner checklist

These are settings and choices only the server owner can make. The AI builds the resource; nothing here changes its code.

- ☐ Set each department's supervisorGrade to your real Qbox grade level. SC-Dispatch's roster treats grade 4 and up as command staff.

- ☐ Replace the placeholder payouts in Config.MissionTypes and Config.Events.weeklyBoss with amounts that fit your economy.

- ☐ Give admins the ace in server.cfg, e.g. add_ace group.admin crimsonpolice.admin allow.

- ☐ Add the webhook convars you want (cp_webhook_board, cp_webhook_audit, cp_webhook_flags, cp_webhook_builder, cp_webhook_operations) and leave out any you don't.

- ☐ Put each department's logo in Crimson-Police/logos/.

- ☐ Keep Config.Integrations.CrimsonArena in SC-Dispatch and Config.ArenaIntegration.Enabled in SC-Ambulance set to true. Mission alert suppression depends on both.

- ☐ Make sure every department's job is in SC-Dispatch's Config.Police.AllowedJobs and SC-Police's Config.DispatchIntegration.PoliceJobs (sast, fib and bcso already are).

- ☐ Check that the Bolingbroke zone in Config.Builder.noBuildZones covers your prison interior. SC-Police treats anyone within 200 m of the prison's middle point (Config.Prison.Locations.middle in its prison config) as inside the prison, so that point with a 200 m radius is the safest setting.

- ☐ Decide whether SAST should stop creating shots-fired calls outside missions. SC-Dispatch only skips them for on-duty police, bcso and fib. Adding sast is a small edit to that check in SC-Dispatch (client/main.lua, in TriggerShotsFiredAlert) that you make yourself; the Crimson-Police build never edits SC-Dispatch.

- ☐ Set the server machine's time zone to your community's. Every "server time" in this spec (daily and weekly resets, the Weekly Boss days) uses it.

- ☐ Back up your database before every Crimson-Police update.

- ☐ Give the database user permission to create and alter tables. Crimson-Police creates and upgrades its own tables on start, so there is no SQL to import.

- ☐ When updating, keep your config/, logos/ and missions/custom/ folders.

## Appendix: integration reference

These calls were read from the uploaded copies of the resources. Use only these calls, only from modules/integrations/, and never edit the resources themselves.

qbx_core (Qbox APIs only, as used by the installed SC resources and Renewed-Banking)

| Call | Side | Use in Crimson-Police |
|---|---|---|
| exports.qbx_core:GetPlayer(src) | Server | The Qbox player object: PlayerData.citizenid, charinfo.firstname and lastname, job.name, job.label, job.grade.level (supervisor check), job.grade.name (rank), job.onduty, job.type, metadata.callsign, metadata.isdead, metadata.inlaststand |
| exports.qbx_core:GetPlayerByCitizenId(citizenid) | Server | Find online officers for invites and payouts |
| exports.qbx_core:GetQBPlayers() | Server | Every online player, e.g. to notify on-duty officers of a Cross-Department launch (a Qbox export, despite its name) |
| exports.qbx_core:GetJobs() | Server and client | Job labels and grade names for the UIs |
| player.Functions.AddMoney(moneyType, amount, reason) | Server | Cash payouts (moneyType = Config.Cash.account). player is the object returned by exports.qbx_core:GetPlayer(src); this is allowed, the QBCore core object is not |
| exports.qbx_core:GetPlayerData() | Client | Current job, rank, duty and metadata for the tablet |
| Event QBCore:Server:SetDuty (src, onDuty) | Server | Going off duty mid-run removes the officer as Abandoned (off_duty) |
| Event QBCore:Server:PlayerLoaded (player) | Server | Pays pending cash and refreshes the stored callsign and rank |
| Events QBCore:Client:OnJobUpdate, QBCore:Client:SetDuty (onDuty), qbx_core:client:onGroupUpdate, QBCore:Client:OnPlayerUnload | Client | Refresh or close the tablet when the job, duty or character changes |

qbx_core fires the QBCore:-named events itself (Qbox kept those names), so listening to them is Qbox-native; Hard rule 2 bans the QBCore core object and QBCore.Functions, not these events. Downed = the ped is dead, or the player's metadata has isdead or inlaststand set to true (the same check sc-dispatch and sc-ambulance use).

sc-police

| Item | Detail |
|---|---|
| Police jobs | Config.DispatchIntegration.PoliceJobs = { 'fib', 'sast', 'police', 'bcso' }; police jobs have job.type = 'leo' |
| Ranks | The Qbox job grades: job.grade.name is the rank shown on the tablet, and job.grade.level is compared with supervisorGrade. Crimson-Police never changes grades |
| Callsign | /callsign <name> saves metadata.callsign with SetMetaData; Crimson-Police only reads it |
| Duty | Standard Qbox duty (job.onduty). sc-police forces suspended officers off duty through QBCore:Server:SetDuty |
| Stations | Duty points: Mission Row PD (470.63, -974.11, 30.18), Sandy Shores BCSO (1833.06, 3679.32, 33.19), SASP (1560.38, 815.76, 76.21) and FIB HQ (466.76, -947.90, 37.25); the default no-build zones cover them |
| Export GetCurrentCops() | Exists on the server; Crimson-Police does not need it |
| NPC arrests | Crimson-Police uses its own ox_target "Cuff suspect" action for NPCs, never sc-police's player cuffing or jail |
| Prison | sc-police's prison files are not loaded by its fxmanifest; Prison Break only spawns outside the walls anyway |

sc-dispatch

| Call | Side | Use in Crimson-Police |
|---|---|---|
| Net event sc-dispatch:server:ToggleResponding (callId, isResponding) | Server listener | A second, read-only handler. sc-dispatch's client sends it when an officer responds, when a dispatcher assigns them (AutoResponding = true) and when they are detached, so it covers every real-call case. callId is the call's unique_id when it has one, otherwise its row id |
| Table mdt_dispatch (read-only) | Server | Confirms a call is real and active: SELECT unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1, with the number and the string form of callId; an unknown or inactive call is ignored |
| Event sc-dispatch:server:callClearedByOfficer (callId) | Server listener | Remove that call from the responding map |
| playerDropped | Server | Remove the player's responding entries |
| Net event sc-dispatch:server:ShotsFired (data: coords, street, zone) | Server listener | The backstop. sc-dispatch names the call shots_<src>_<os.time()>; if the sender is an In-progress participant within 300 m of their mission, wait 1 second and clear it |
| exports['sc-dispatch']:ClearNotification(uniqueId, jobTable) | Server | Clears a call that slipped through: ClearNotification('shots_<src>_<time>', { 'police' }) for the current and the previous second. Any job list containing police clears the call for every job in SC-Dispatch's Config.Police.AllowedJobs, which already lists sast, fib and bcso |
| State bag crimsonArena | Both | With Config.Integrations.CrimsonArena = true (already set), sc-dispatch's IsInCombatSafeZone() skips shots-fired, person-down and person-dead calls while LocalPlayer.state.crimsonArena.active is true. Crimson-Police sets it with Player(src).state:set('crimsonArena', { active = true, source = 'crimson-police' }, true) |
| exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobname) | Server | Refuse suspended officers |
| exports['sc-dispatch']:AddNotification(data) | Server | Do not use: missions never create dispatch calls |
| Call id formats | — | shots_, panic_, emshelp_, playerdown_ and playerdead_ followed by <src>_<time> (sc-dispatch); emsdown_<src>_<time> (sc-ambulance); npccall-<n>-<time> (sc-npcpolice) |
| Shots-fired exemption | — | Outside Crimson-Police, sc-dispatch only skips shots-fired calls for on-duty police, bcso and fib, and alerts the jobs in Config.Dispatch.ShotsFired.AlertJobs (which include sast and fib) |
| Roster | — | Config.Roster.CommandGrade = 4: grade 4 and up count as command staff in SC-Dispatch |
| Net event sc-dispatch:client:AssignedToCall (info) | — | Not needed: the assigned officer's client also sends ToggleResponding |
| Net events sc-dispatch:server:PlayerDown and sc-dispatch:server:PlayerDead (data) | Server listener | Backstop for person-down and dead calls: sc-dispatch names them playerdown_<src>_<time> and playerdead_<src>_<time>. Clear them with { 'police', 'ambulance' } only if the sender still carries the Crimson-Police flag |

Auto-cleared calls fire no event, so a responding entry expires 20 minutes after the officer's last ToggleResponding (Config.Calls.respondingExpiry). While an officer has a live entry for a real call, the server refuses their mission accepts ("On a call").

sc-multijob

| Item | Detail |
|---|---|
| Holding jobs | A player holds up to 5 jobs in PlayerData.jobs; PlayerData.job is the active one |
| Switching | sc-multijob:server:switchJob calls exports.qbx_core:SetPlayerPrimaryJob. Crimson-Police re-checks the active job on every objective and every 10 seconds during a run (Config.AntiCheat.jobRecheck) |
| Duty | sc-multijob:server:toggleDuty calls exports.qbx_core:SetJobDuty |
| Exports | None; do not trigger its events |

Renewed-Banking

| Call | Side | Use in Crimson-Police |
|---|---|---|
| exports['Renewed-Banking']:handleTransaction(account, title, amount, message, issuer, receiver, type, transID) | Server | Record each payout. account = citizenid (personal) or the society account; type = 'deposit' or 'withdraw'; transID = CP-<run_uuid>-<citizenid> |
| exports['Renewed-Banking']:removeAccountMoney(account, amount) | Server | Society source only; returns false when the account cannot cover it |
| exports['Renewed-Banking']:getAccountMoney(account) | Server | Society balance shown in the Admin UI |
| Personal balance | Server | Renewed-Banking reads Qbox money, so the deposit itself is player.Functions.AddMoney('bank', …); handleTransaction only records it in the bank history |

sc-ambulance

| Call | Side | Use in Crimson-Police |
|---|---|---|
| exports['sc-ambulance']:GetDoctorCount() | Server | On-duty ambulance players; 0 means no EMS, so a downed participant is picked up |
| Client event hospital:client:Revive | Server → client | TriggerClientEvent('hospital:client:Revive', src) revives a picked-up officer; SC-Ambulance's own server code revives players the same way |
| Net event hospital:server:EMSDownAlert (street) | Client → server | Sent from the downed officer's own client after their flag is removed; SC-Ambulance creates an emsdown_<src>_<time> call for EMS through sc-dispatch. It ignores flagged players and players who are not down |
| State bag crimsonArena | Both | With Config.ArenaIntegration.Enabled = true (already set), SC-Ambulance sends no automatic person-down alert for flagged players |
| Net event hospital:server:RevivePlayer | — | Never trigger it: SC-Ambulance bans any sender who is not EMS and carries no first aid |
| Check-in points | — | Pillbox (308.19, -595.35, 43.29) and Paleto (-254.54, 6331.78, 32.43): the default drop-offs in Config.Downed.dropOffs |
| Respawn | — | SC-Ambulance's own hospital respawn bills the player and keeps their inventory (WipeInventoryOnRespawn = false); Crimson-Police's pick-up is free |

sc-npcpolice

| Item | Detail |
|---|---|
| Call ids | Created through sc-dispatch's AddNotification with unique_id = ('npccall-%d-%d'):format(nextCallId, os.time()), so every NPC call id starts with npccall- |
| Rewards | SC-NPCPolice pays for its own calls; Crimson-Police never scores or pays them |
| Calls | Crimson-Police never calls, triggers or edits SC-NPCPolice; it only reads call ids |

ox_lib, ox_target, ox_inventory and oxmysql are used through their standard, documented APIs.

