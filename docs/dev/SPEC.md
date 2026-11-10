# Crimson-Police – Tablet Missions & Leaderboard Spec

Sep 30, 2026 · @John Wood · English only

Crimson-Police is a Qbox police tablet (/CrimsonPolice) with its own custom UI. It gives on-duty SAST and FIB officers random NPC missions by mission type, pays cash through Renewed-Banking and ranks officers on leaderboards. Read Hard rules first: they override every other section, and the files in config/ override any number in this document.

## Hard rules

These rules override everything else in this spec. If another section, example or number disagrees with a rule here, the rule wins.

- Stack: Crimson-Police MUST run on Qbox (qbx_core) and MUST use only these resources: sc-police, sc-dispatch, sc-ambulance, sc-multijob, Renewed-Banking, oxmysql, ox_lib, ox_inventory and ox_target. It MUST recognise calls made by sc-npcpolice without calling it. It MUST NOT require, bridge to or edit any other resource. When Config.RealPlayers.liveCrime is on it MAY listen to Crimson-Contracts' server-only lifecycle events (crimson-contracts:server:*) and it offers the read-only export GetAvailablePolice; it never requires Crimson-Contracts.

- Qbox only: all framework access MUST go through exports.qbx_core, the Qbox player object it returns (for example player.Functions.AddMoney, which is Qbox's own API) and the events qbx_core fires. Crimson-Police MUST NOT use the QBCore core object (exports['qb-core']:GetCoreObject(), QBCore.Functions) or list qb-core as a dependency, even though Qbox ships a QBCore compatibility layer.

- Names: the resource folder MUST be Crimson-Police (events, callbacks and tags keep the lowercase prefix crimson-police) and the tablet MUST be titled "Crimson-Police". The officer command MUST be /CrimsonPolice and the admin command MUST be /CrimsonPoliceAdmin. Volunteer suspects use the command in Config.RealPlayers.volunteer.command (default /crimsonheat).

- Access: only on-duty players whose active Qbox job belongs to a department in Config.Departments MAY use the Officer UI. There are no activation requirements: no activity check, no minimum officers online and no quiet timer. Exception (owner decision): a mission type or mission set to 'players_only' in Config.RealPlayers.volunteer is offered only while a volunteer suspect who fits is online.

- Roles: there are exactly three roles: Officer, Supervisor (job grade at or above the department's supervisorGrade) and Admin (ace crimsonpolice.admin, or a Qbox admin, the ace admin that stock Qbox gives group.admin, while Config.QboxAdmins is true). There are no cadet, detective or other roles. Supervisors get the same missions as officers. Ranks and callsigns are read from Qbox, as SC-Police sets them, and are never edited by Crimson-Police.

- Mission choice: officers and supervisors MUST only pick a mission type on the Mission Board or claim a mission call on Dispatch, and the server MUST draw the mission at random after the claim. A call names a type, a priority and an area, never a mission; it names an area to a viewer only when his eligible pool there (after unit size, no-repeat, cooldowns and daily limits) holds at least 2 missions, else "County-wide" from the board's pool, so a call is never narrower than the board. Staff-posted or paged calls draw at random like any other and never go to the issuer's own unit. The Officer UI MUST NOT list, preview or let anyone pick a specific mission, and there is no reroll. Only five exceptions exist: the Weekly Boss event card; a mission launched as a Cross-Department Mission; test runs (Admin test mode and the builder's draft test), never saved or paid; a LIVE call (a real crime reported by Crimson-Contracts: no draw); and a mission pushed to one unit of the supervisor's own department (the pushMission Mission control, owner decision, shipped off; its rules are under Mission controls). A 'players_only' type (Config.RealPlayers.volunteer) draws only from missions that can take a volunteer, still at random.

- Cross-Department Missions: while one is active, every department's Mission Board MUST show only that mission, and the server MUST refuse every other new mission until it is completed or cancelled. Admin test runs are the only exception.

- Teams and scaling: officers from any department MAY team up. Missions MUST scale with the number of participants, and cash MUST scale with the resulting difficulty.

- Cash payouts: every mission pays its mission type's payout × its star multiplier (the Weekly Boss pays its own event payout from config) unless an admin has set a payout for that specific mission. Supervisors MAY change a type's payout only if no admin has set it, and only within Config.Payouts.supervisorRange. A supervisor may raise a cash bonus only inside admin-set bounds (the happyHourCash and twistCash Mission controls), never on test runs, Cross-Department runs or the Weekly Boss, and always under Config.Cash.dailyCap. Only admins MAY set a single mission's payout. Any payout an admin sets is permanent until an admin changes or clears it.

- Points: leaderboard points come from Config.MissionTypes and the scoring rules. Officers MUST NOT be able to change points in game. Supervisors MAY give points only through Mission controls an admin switched on (owner decision), inside the admin's bounds, never for themselves, their other characters or their unit, never on test, Cross-Department or Weekly Boss runs, audited: typeOfTheDay, happyHourPoints, twistPoints, goals (which of the admin's goals in Config.Objectives their department draws from the next weekly reset) and awardPoints (a logged manual award through the admin's point-adjust path and its guards). Only an admin MAY change point values: a point setting in Admin UI → Settings (audited) or a logged manual award or deduction (a new signed row, never an edit; see Full admin control).

- Server authority: the server decides draws, scaling, points and cash. The client MUST NOT send point or cash amounts; it only reports objective events, which the server validates.

- Departments: department names, colours and logos come only from Config.Departments. Adding a department there and restarting, or adding it from the Admin UI, MUST make it work everywhere with no code or SQL changes.

- Custom interfaces: the Officer UI, Supervisor UI and Admin UI are separate, custom standalone NUI built for Crimson-Police, together with its Mission Builder, mission HUD and notifications. Each shows only its own screens, and the server MUST re-check permissions on every action. The only outside UI allowed is ox_target's interaction prompts, ox_inventory's own inventory screens, and ox_lib's progress bar and skill check during missions. Volunteer suspects are not police and have no tablet: they get ox_lib notifications, alert and input dialogs and a context menu from the volunteer command only.

- NPCs only: missions MUST involve only NPCs, except live crimes (Config.RealPlayers.liveCrime) and volunteer suspects (Config.RealPlayers.volunteer), both off by default, whose suspects are real players who chose it (a crew whose contract alerted police, or a player who volunteered and said yes). They MUST NOT create SC-Dispatch calls (the one exception is the EMS request sent for a downed participant while EMS is on duty), target real players or spawn anything a non-participant can take.

- Real calls first: when a participant is assigned to, or marks themselves responding to, a real SC-Dispatch call (any call not created by SC-NPCPolice), their run MUST end at once with no penalty and no cooldown. SC-NPCPolice calls MUST NOT end a run. There are exactly three exceptions: un-marking responding within 60 seconds turns the free abandon into a normal one (type cooldown), a call raised about a participant of the same run (their person-down, dead, EMS or panic call) does not end their partners' runs, and in a case with a real suspect, the case's own linked SC-Dispatch call and calls raised by or about its suspects and participants (shots fired, person down, dead, EMS, panic) do not end it.

- No mission alerts: from the moment a participant reaches the mission start until their run ends, their mission combat MUST NOT create SC-Dispatch or SC-Ambulance alerts (shots fired, person down), and any such call that still appears in SC-Dispatch MUST be cleared automatically. A downed participant can still get EMS help. In a case with a real suspect, Config.RealPlayers.officerAlerts decides; shipped: alerts go out like any officer's.

- Route to the start: participants MUST follow the route shown to the mission start; staying off it ends their run as Abandoned. The owner may switch this rule off (Config.Route.required = false): the route is still shown and checked for arrival, but leaving it never ends a run. A run keeps the value it was accepted with, and a test run follows its own Start route switch. Late partners (owner decision): once the run is In progress, a participant still on his way follows the action: his route is no longer checked, his GPS leads to the current objective, and he arrives within Config.Route.lateArriveRange (150 m) of it or at the start (0 = only the start counts), within Config.Route.followActionSeconds (300 s) from then, never less time than he had. In a case with a real suspect, Config.RealPlayers.routeEnds decides; shipped: the route ends at the first contact with a suspect. On a live crime Config.RealPlayers.liveCrime.requireRoute (shipped false) replaces Config.Route.required: officers on a live case may leave the GPS route to chase. Volunteer-suspect missions follow Config.Route.required.

- Downed participants: a participant who goes down has Failed their run. If no EMS is on duty, they MUST be picked up automatically (revived and moved to a drop-off point). In a case with a real suspect, Config.RealPlayers.downed and downedPickupDelay decide; shipped: a downed officer keeps what he earned, no type cooldown, pick-up after 400 s.

- Cleanup: every entity, blip, zone and mission item MUST be removed when a run ends for any reason, including disconnects and resource stops.

- Mission Builder: it runs inside Crimson-Police's own UI: on the tablet in the Supervisor UI, and in the Admin UI panel for admins. Every custom mission MUST have a mission type and MUST NOT have a payout field. Recorded routes are saved as roads, not as the exact line the builder drove. Publishing MUST write a Lua file that developers can edit. An admin may edit a built-in mission there too: the edit is an override saved under the same mission id in missions/custom/overrides/, never in missions/builtin/, and Reset to original removes it (see Full admin control).

- Code layout: each feature MUST live in its own folder under modules/, each objective block in its own folder under blocks/, and each mission in its own file under missions/, so every part can be edited and debugged on its own (see Architecture).

- Config wins: if a number in this document and the files in config/ disagree, the config value wins.

## Do not build

Everything below was considered and removed. Do not add it back, even as an option or a disabled config flag.

- Missions: Traffic Control, DUI Checkpoint, Abandoned Vehicle (a plain tow job), Range Qualification, Evidence Recovery, Rooftop Shooter, Air Support, Harbor Interdiction, and anything using cones. Traffic Enforcement (pacing one moving violator at a time, stopping it and working the contact), Illegal Parking Patrol (a judgement sweep of parked cars) and Suspicious Activity (a scene contact that ends in a decision) are allowed as their mission cards describe them.

- Activation: no server activity state (Quiet / Busy / Active), no priority-traffic command, no minimum officers online (a 'players_only' type needing a volunteer is the owner's choice, see Access), no mission pause and no Expired state (the maintenance lock of Full admin control is not a pause). Mission calls lapse when nobody claims them; a lapsed call is not a run state, and nothing pauses the Mission Board except the Cross-Department lock.

- Mission choice: no list of individual missions on the officer Mission Board, no picking or previewing a specific mission (apart from the Weekly Boss card, Cross-Department Missions, test runs and a mission staff push to one unit, the pushMission Mission control), no reroll.

- Roles: no cadet, detective, FTO or supervisor-only missions, no grade-restricted mission pools, and no separate builder permission.

- Payouts and points: no in-game editing of points by officers, no point values edited by supervisors (only through the Mission controls the Points Hard rule names; admins only through logged Settings or manual awards), no point awards from other resources (another resource may report a crime; every point is still computed by Crimson-Police's scoring), no supervisor editing of single-mission payouts, and no payout field in the Mission Builder or in exported Lua files.

- Leaderboards: no manual board reset; boards are time windows, and corrections are made by voiding runs (one by one or as a bulk void of an officer, an operation or a board window, which is always restorable as a batch).

- Framework: no QBCore core object, no QBCore.Functions, no qb-core dependency, and no QBCore or ESX bridges.

- Languages: Crimson-Police ships English only (locales/en.json). No other language files, no per-player language picker and no language switching beyond what exists.

- Integrations: no other dispatch, inventory, target, banking, medical or tablet resources; no edits to sc-police, sc-dispatch, sc-ambulance, sc-multijob, sc-npcpolice or Renewed-Banking; missions never create SC-Dispatch calls (apart from the EMS request for a downed participant); never trigger SC-Ambulance's hospital:server:RevivePlayer (it bans any sender who is not EMS).

- UI: one custom UI stack only (React + TypeScript + Vite); no ox_lib menus, context menus, input dialogs or notifications for Crimson-Police screens, except the volunteer command's ox_lib dialogs (Custom interfaces); no third-party tablet; no Crimson-Police tab inside the SC-Dispatch MDT.

- Rule switches: no config flag that turns off Hard rules 15, 16 or 18 (real calls, alert suppression, downed participants). Their numbers are configurable; the rules are not. Hard rule 17 (the start route) is the one exception: the owner made it switchable with Config.Route.required (see that rule). In cases with a real suspect, Config.RealPlayers.officerAlerts, routeEnds, downed and downedPickupDelay choose between the rule for real players (shipped) and the NPC rule, and Config.RealPlayers.liveCrime.requireRoute sets the start-route rule for live crimes (shipped false). For NPC missions rules 15, 16 and 18 stay on.

## Glossary

Each term means exactly this everywhere in the spec; terms with their own section (roles, units, tiers, scoring, payouts, mission calls, contacts, events, profile) are defined there.

| Term | Meaning |
|---|---|
| Mission type | Patrol, Training, Investigation or Tactical; the only mission choice officers make (the twists they may add change how the drawn mission plays, never which mission is drawn) |
| Pool | The missions of a type that can currently be drawn for an officer or unit |
| Run | One attempt at a drawn mission, from accepting the type until it ends |
| Objective / block | One step of a mission; blocks are the reusable step types missions are built from |
| Real call | Any SC-Dispatch call not created by SC-NPCPolice |
| NPC call | A call created by SC-NPCPolice; its call id starts with npccall- |
| Driving a vehicle | In a vehicle and in its driver seat, as the server sees it; any vehicle counts. Where a mission needs it (Beat Patrol, EVOC Course, checkpoint_route with "Vehicle required" on), a checkpoint counts only while the officer is driving a vehicle |
| Base payout | The mission's admin payout if one is set; otherwise its type payout × its star multiplier (the Weekly Boss: its event payout from config) |
| Cash payout | Money each participant receives for a Completed run: base payout × tier multiplier × twist multiplier |
| Twist (modifier) | A harder way to play a run (Armored Hostiles, Time Crunch, Radio Silence) that the officers choose when they take the mission; each adds its own points and cash, and they stack |
| Area | One of Config.MissionCalls.areas; every mission location belongs to the area whose centre is nearest |
| Contact | A person (subject) or vehicle that a field_contact objective owns, with a hidden truth |
| Truth | What is really going on with a contact, rolled by the server at the start of the objective and never sent to clients, not even as a weapon, a demeanour or a hint before the behaviour it causes starts |
| Fact | A part of the truth revealed to the run by a validated police action |
| Disposition | The decision recorded for a contact: Release, Warn, Cite or Arrest for a person; No action, Cite or Impound for a vehicle |

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

Out of scope: civilian-facing missions, missions for EMS or fire, and anything that uses real players as mission targets, except live crimes and volunteer suspects (off by default).

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
| ox_inventory | Optional tablet item (and the "require the item" mode), items a mission hands out and takes back, optional handcuffs check, optional item rewards |
| ox_target | Interacting with mission props, doors, NPCs and vehicles, and mission desks |

The Appendix lists the exact exports and events used from each of these resources.

Decisions not stated elsewhere: Crimson-Police has its own standalone tablet (/CrimsonPolice), never a tab in the SC-Dispatch MDT; the job names are sast and fib as sc-police and sc-dispatch use them; "Rank" only ever means the Qbox grade name (XP tiers are XP levels); cadets and detectives are not roles; cash is new money by default, switchable to the department's Renewed-Banking account; star multipliers exist but are 1.0, so builders can't raise pay with stars; only being assigned or marking responding ends a mission, never seeing an alert; leaving the route in a unit ends only that officer's run.

Assumptions

- All draws, scaling, points and cash are decided server-side; the client only reports events.

- Missions are local to their participants and never spawn anything other players must interact with (a volunteer suspect is the one non-participant a mission may involve).

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
| Officer UI | On-duty member of a department in Config.Departments | /CrimsonPolice, keybind, tablet item or a mission desk | The officer's department theme and logo watermark |
| Supervisor UI | Officer with a grade at or above their department's supervisorGrade | "Supervisor" switch inside the Officer UI | The supervisor's department theme and logo watermark |
| Admin UI | Anyone with the ace crimsonpolice.admin (or a Qbox admin while Config.QboxAdmins is true), on duty or not | /CrimsonPoliceAdmin, a full-screen panel of its own, not the tablet | Neutral Crimson-Police theme, no watermark |

Every screen shows "Crimson-Police" as the app title. The Officer and Supervisor UIs also show the viewer's department name and tag, rank and callsign in the header, e.g. "San Andreas State Troopers · SAST · Sergeant · 2L-14". Rank and callsign are read live from Qbox, as SC-Police sets them.

Officer UI — eight screens on a left sidebar, with the officer's current run pinned to the top of every screen.

| Screen | Contents | Key actions |
|---|---|---|
| Home | Officer card (avatar, callsign, rank, tag, level, streak and grace day, season points, cash this week), daily and weekly goal, Type of the Day, open calls, "Missions today n/max" under a daily cap, new commendations, the Rewards locker | Open the board or Dispatch, claim a locker item |
| Mission Board | One card per type: cash per officer, points, pool size, solo or unit, cooldown, "Server busy", "On a call", "Daily limit reached"; the Weekly Boss card Friday–Sunday; only the operation's card during a Cross-Department Mission; "n mission calls open" | Accept a type (the accept step lists its twists and their total, e.g. "+45% points, x1.50 cash"; a type a volunteer suspect may play shows "Real suspect" and needs the leader's "Real suspect OK" tick), join an operation |
| Dispatch | Open mission calls (code, radio-style title, type, priority, area, distance, offer countdown, crew, pay, status), the last 5 calls with who took them and how they ended, the read-only SC-Dispatch real-call strip, notices (on a run, on a call, Cross-Department Mission active) | Claim a call (leader or solo), filter, mute call alerts |
| Unit | Members with avatar, level, rank and callsign; invites waiting for you; the ready check | Invite, withdraw an invite, accept or decline, leave; leader: kick, make leader, disband (before a type is accepted); answer the ready check |
| Active Mission | Drawn mission, tier (expected until In progress), route status (on route, countdown, "Joining your partners"), objectives, timer, partners, expected cash and points, the Contact panel, a raid's intel line, a call's response target | Set GPS, Recalculate route (2 per run), Objective GPS (at the action: a waypoint on the objective), abandon |
| Leaderboard | Tabs Weekly · Monthly · Season · All-time; filters for mission type, unit, cross-department and department; top 25 plus your own row pinned; "Rank by" (Points, Missions, Arrests, Impounds, Citations, Rescues, Mission calls, Judgement) and a level column | Tap an officer to view their public profile |
| Department Challenge | Score bar per department, weeks left, this week's bounty, your department's top 5 contributors | Tap a department to see its contributors |
| Profile & History | Avatar, bio, level and XP bar, service record, badges, commendations, last 20 runs with points, cash, decisions and how each ended | Edit profile (picture, bio, look), report a profile, open a breakdown, dispute a flagged, voided or failed run from the last 48 hours |
| My options | See Officer profile → Officer options | Change an option (saved half a second after the last change, inline Saved), Back to default |

Supervisor UI — its own layout and sidebar. Supervisors play missions from the Officer UI exactly like officers; the Supervisor UI is for oversight.

| Screen | Contents | Key actions |
|---|---|---|
| Mission List | Every mission by name, built-in and custom: type, difficulty, officers supported, current base payout, cooldowns, who is running it now. Officers never see this list | Launch a Cross-Department Mission (missions open to every department that support 2+ officers; never the Weekly Boss) |
| Cross-Department Mission | The active operation: mission, launcher, joined participants by department, tier, status | Start now, relaunch after a fail, cancel |
| Live Missions | Runs involving their department: participants, mission type, drawn mission, tier, time left | Force recall |
| Review Queue | Flagged runs with the reason, and disputes about flagged or voided runs, of their department (never their own runs) | Approve, void or reject (reason required) |
| Payouts | Payout per mission type, with the allowed range; a type an admin has set shows "Set by admin" and is read-only; single-mission payouts are not shown | Change an unlocked type's payout (within range, once per 30 minutes per type) |
| Mission Builder | Their drafts plus published missions | Build, record routes, test, publish, archive; roll back or break an edit lock (as Config.Permissions allows) |
| Department Report | Challenge standing, this week's bounty, officer activity this week | Open an officer's activity |

One Department screen (MG3): Department Report, Mission controls and Review Queue are no sidebar entries of their own but tabs of one Department screen (sup_department): Officers (the Department Report and each officer's actions), Controls (Mission controls, each control's admin limits and today's use inline from sup:getMyControls, the action controls in one card), Review (the Review Queue), Calls & notices (the Mission calls panel, moved off Live Missions, and the department notices) and Training (field training). Each tab keeps the permission of the screen or panel it replaces; the old keys sup_report, sup_controls and sup_review open their tab (params kept); the Review Queue badge sits on Department. UI4: above the tabs, today at a glance (sup:getToday, viewMissionList: the department's officers on duty, its runs going as Live Missions lists them, the viewer's Mission controls with a day count as used / day counts summed; plus the sidebar's Review Queue count with the Review tab), each opening its tab or Live Missions; an officer opens one side panel (his week, commendations and every action the viewer may take on him: Give points, Mission ban or Lift, Clear cooldown, Commend, Field training), each form in the panel; permissions, caps and audit rows unchanged.

Supervisor UI additions: Live Missions gets a Mission calls panel (withdraw, page a unit, create a call; on Department → Calls & notices since MG3); Review Queue gets a Profiles tab (pending pictures, pending bios when bioRequiresApproval is on, and profile reports); Department Report gets arrests, citations, impounds, correct decisions and calls per officer, and "Commend" in each officer's activity.

Admin UI — a separate full-screen panel for server admins, covering every department.

| Screen | Contents | Key actions |
|---|---|---|
| Payouts | Every mission type and every mission with its base payout; admin payouts marked "Set by an admin" | Set or clear a type or mission payout |
| Missions | Every mission with version, file path, "edited in code", edit locks, and on/off switches per mission and location (over Config.DisabledMissions / DisabledLocations; running runs finish) | Build, publish, archive, restore, roll back; break a lock; reload files; switch missions and locations; run Cross-Department Missions |
| Seasons & Challenge | Current season, department standings, bounty history | Start or end a season, override this week's bounty |
| Leaderboards | Every board and period, cash paid per officer, and any payment left in paying after a crash | Void runs, award points |
| Officers | Search any officer: rank, callsign, history, badges, cash earned, suspensions, disputes about failed runs | Suspend, unsuspend, answer a dispute (manual award or dismiss) |
| Departments | Each department in Config.Departments: name, jobs, colours, logo thumbnail, member count, society balance (only when Config.Cash.source = 'society') | Preview a department's tablet theme (read-only) |
| Permissions | Config.Permissions: which supervisor actions are switched on; extra grants; Config health | Switch a supervisor action on or off; give a power to departments from a grade, Qbox gangs from a grade or single citizenids (Extra grants). Both are settings saved over config.lua and audited |
| Settings | Every setting by section with its comment, the value in use and config.lua's, "changed" and "after restart" badges, Config health, the change history | Change, reset one or all (Settings changed in game) |
| Audit Log | Every supervisor and admin action, filterable | Export |
| Testing | Every mission and each of its locations with its last test result (Passed, Failed, Not tested or Changed since test), the tier, who tested it and when | Start a test run (mission, location, tier, start route on or off), invite testers, record a result |

Admin UI additions: Officers gets profile moderation (clear bio or picture), commendations (give, revoke) and the service record; Leaderboards gets an Item rewards tab; Departments lists mission desks and previews personal accents and appearances; Testing gets the area coverage matrix (mission type × area); Permissions gets Config health.

Sidebar badges: Unit (invites), Active Mission (a live dot on a run), Dispatch (claimable calls), Profile (new commendations), Home (rewards waiting), Review Queue (open items), updated from the live push topics. The header bell lists the session's last 20 toasts; the header shows the avatar and level badge next to the callsign (the rank stays the Qbox grade name).

UI build: React 18 + TypeScript built with Vite into web/dist (Hard rule Custom interfaces). All text is in locales/en.json. Opening the Officer UI plays a tablet prop and animation; closing removes the prop.
## Tablet access

| Way | Config | Server check |
|---|---|---|
| /CrimsonPolice | Config.Tablet.access.command | As today |
| Key mapping crimsonpolice_tablet | access.keybind | As today |
| Key mapping crimsonpolice_dispatch (opens on Dispatch) | access.keybind and Config.Tablet.dispatchKey | As the keybind |
| The tablet item | access.item and Config.Tablet.item | As today; with requireItem the item must be in the inventory |
| Export OpenTablet() | always on | As today |
| Mission desk | access.desk and Config.Tablet.desks | The player is within the desk's box plus 2 m, and the desk allows their department |

- Every way ends in the same server check (department, duty, active job, suspensions, Crimson-Arena), and a way that is switched off is refused.

- requireItem = true: every way except a mission desk needs the tablet item in the inventory, checked on the server with ox_inventory; the tablet closes when the item leaves the inventory. Accepting a mission and claiming a mission call check the item again (not needed while the officer is still at the desk the tablet was opened at).

- Mission desks are ox_target zones ("Open Crimson-Police") created on the officer's client from config (coords, size, rotation, departments, an optional laptop prop that only that client sees). At a desk the officer plays a standing-at-a-computer animation instead of holding the tablet, and the tablet closes when they walk more than 3 m away. Desks never show for players in Crimson-Arena and are removed when the resource stops.

- Three desks ship, one per police station qbx_policejob knows: Mission Row PD and Paleto Bay 1.5-3 m from its duty points (config/shared.lua:21 and :22) in the base-game interiors, facing them, and Sandy Shores at its earlier spot (Qbox has only a map blip there); each config.lua line names its source and tests/setup_coords_spec.lua checks it. A custom station MLO may need a desk moved. Admin UI → Departments lists each department's desks, and its Desks tab adds a desk where the admin stands, moves, edits, removes and teleports to one (live, audited).

- The resource ships items/crimson_police_tablet.png and items/ox_inventory_items.lua, a snippet to paste into ox_inventory's items; Crimson-Police never edits ox_inventory.

## Departments & tablet theming

Each Config.Departments entry sets that department's name on the tablet, its colours and its logo watermark (SAST and FIB ship; adding one is a config change and a restart).

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
| theme.personalAccents | Optional list of accent colours (or { colour, level }) an officer of this department may pick for their own tablet |

Theme colours

| Key | Used for |
|---|---|
| primary | Header bar, primary buttons, active sidebar item, progress bars |
| accent | Highlights, badges, focus outlines, the Type of the Day tag |
| background | Tablet body behind all content |
| surface | Cards, tables and dialogs |
| text | Main text. Optional: when left out it is picked automatically (white or near-black) for contrast with background |

Colours are 6-digit hex values such as #1f4e8c. A missing or invalid colour falls back to the Crimson-Police default with a console warning.

Personal accent and appearance

- The department theme is the identity: primary colour, header, logo and watermark always come from Config.Departments; the Admin UI always uses Config.AdminTheme.
- An officer may pick a personal accent from his department's theme.personalAccents (some unlock at a level); it replaces the department accent on his own tablet only.
- Appearances are accessibility presets from the department's colours: Department, Midnight (background and surface 40% darker), High contrast (WCAG AAA text and surfaces) and Colour-blind friendly (success and danger become blue and orange). None changes the primary colour, logo or watermark.

Layout options (presentation only: screen keys, visibility and links never change; the code is in web/src/layouts/, see docs/dev/ARCHITECTURE.md §12)

- Supervisor UI: the sidebar is grouped by task (people, missions, rewards) with a heading over each. Config.Tablet.supervisorCompact (false) shows icons only; supervisorLanding ('first') opens on 'report' (Department, Officers tab), 'review' (Department, Review tab) or 'live' when visible (anything else = the first screen) until a screen is picked. Department → Controls always shows each control's limits and today's use. Give points, Mission ban and Clear cooldown reopen with the last successful values (page memory only; out-of-range numbers fall back to the min; the server checks again). A decision on a flagged run or dispute is pushed to every other supervisor of the decider's department (an admin without one: every department) with the Review Queue open (asked in the last 75 s).
- Officer UI (Config.Tablet.sidebarOrder 'classic' or 'mostUsed', activeFirst, compactSidebar): 'mostUsed' lists home, board, active, dispatch, unit, me, options; activeFirst moves Active Mission under Home while on a run; compact shows icons only (68 px, names as button titles, badges on the icon). Seven screens (UI5): 'me' holds Profile, Leaderboard and Challenge as tabs (navigate('me', { meTab, citizenid }); commendations badge on Me); Home opens on the status (run, day's missions done, ready), the next goal (today's unless done, else this week's) and one button (Mission Board, or Active Mission on a run); the run bar links to board, dispatch and unit when shown.
- Admin UI sidebar: every screen has a plain name and sits under a job group with a one-line description (People, Missions, Real players, Money, Review, System; Home on top; a group with no visible screen is not shown); the rare tools (Seasons, Leaderboards) fold under More (which carries their badge sum; kept open per viewer in the browser); one search box (Ctrl+K focuses it) lists the matching screens and tabs, up to 5 officers (admin:searchOfficers), up to 5 missions (admin:getMissions, opens the mission's drawer) and up to 6 settings (admin:getSettings, opens Settings on the path), then "Search settings for ..." (Enter opens the first); a breadcrumb over every screen but Home. Review holds the one Review queue (review:getQueue with all: flagged runs and disputes of every department in one list with a Type column and a filter), Profiles and Corrections; admin:getBoards no longer carries the flagged runs. Settings follows the play sections, and Settings → Features lists every feature switch by section with On/Off, a save (risky ones confirm first, money ones need the typed ENABLE) and a link to the setting.
- Restrictions (FM5): one Admin UI screen (People → Restrictions, admin:getRestrictions) lists every restriction running now: tablet suspensions, mission bans, the Real suspects pair blocks, exclusions and suspensions, volunteers' strikes blocks, each with kind, who, until, set by and reason. Extend (whole hours up to the kind's longest; Config.AdminUi.restrictionsExtend, shipped true) and Lift go through server:admin:restriction with a reason; each kind keeps its own permission per step, self rule, switches (RealPlayers.staffLift, volunteer.staffClearStrikes) and audit rows. Setting one stays where it was.
- Admin UI pages: the Map markers screen (NPC missions): the objective's settings and the look of each kind of objective blip, Config.Markers.extraParts (the switch of the extra parts), every part's switch, look and label, and its rules picked from the departments, jobs, mission types and missions, every save a normal setting save. The Admin UI opens on Home, a dashboard from one request (admin:getHome; every minute and shortly after an operation, builder or nav push): Live now (officers on duty by department, the runs going with the liveRuns key, and the queues: flagged runs, profiles, open disputes, stuck payments, open player suspect cases), Alerts (problems, today's refusals, Config health warnings and errors read at most every 30 s, the missions the last load refused) and the shortcuts of Config.AdminUi.homeShortcuts (shipped: builder, catalog, payouts, officers, settings; also live, review, activity; {} = none); four shortcuts hold quick forms (missions and locations on or off, change pay with a reason, give or take points with the typed citizen ID at or above Corrections.adjustConfirmAbove, quick settings) that send the full screens' actions. Config.AdminUi.reasonChips (three texts; at most 8 of up to 60 characters) are buttons under the reason boxes of Set payout, Give or take points and Quick edit that replace the editable reason (Quick edit times are typed in minutes). Settings opens on Simple, the everyday settings with plain labels and no Config path; a switch and a button open All settings (by config.lua section); a search or filter looks through every setting; in Simple, MissionTweaks and DisabledLocations point to Missions.
- Settings inside each screen (UI6): every Admin UI screen but Settings has a gear over it (while the admin may open Settings) that opens a side panel with only that screen's config.lua / blocks.lua sections (modules/settings Play.screens, sent as SettingsData.screens; every section is under at least one gear), searched by label, path or description; the rows, checks, ENABLE prompts, saves and audit are those of Settings, whose All settings still lists every setting. Settings -> Presets lists Config.AdminUi.presets (shipped: casual, serious, golive, in that order, then any other by key; {} = none): Preview (admin:previewPreset, openAdmin) lists each change with its value now and after, counts the settings already at the value and lists any refused row; Apply (server:admin:applyPreset, openAdmin, 1 per 5 s) is refused whole when a row is refused, else saves the changes through Settings.setMany with the reason "Preset: <name>" (each change audited and in the history as a single setting) and adds one settingsPreset audit line. A preset row may not name AdminAce, QboxAdmins, Permissions.*, Database.*, AdminUi.presets, a money switch, a setting whose key mentions webhook or announce, or a locked setting; each value must pass its setting's own check; at most 50 rows per preset.
- Action replies carry the new state (a speed-up only): supervisor and admin actions answer with the screen's new view, which the screen applies and asks again only when it is missing; Active Mission's log gets the next point pushed at once.

Logo and watermark

- Put the logo in logos/ (PNG, WebP or SVG; a square transparent PNG of 1024 × 1024 or more works best) and set logo.file, or set logo.url to a direct https:// image; restart the resource (no UI rebuild).
- The watermark is the logo drawn once, centred behind every Officer and Supervisor screen, fixed while content scrolls, never blocking clicks: logo.opacity (0.0–0.25, 0.08), logo.size (share of the tablet height, 0.6), logo.grayscale; logo.watermark = false keeps only the header logo. A logo that fails to load shows nothing (no broken image) and warns once.

Adding a department (example: BCSO)

- The Qbox job must exist (bcso; sc-police and sc-dispatch already list it). Copy the fib block in Config.Departments, rename the key to bcso, set label, short, jobs = { 'bcso' }, supervisorGrade, societyAccount, theme and logo, put bcso.png in logos/ and restart. BCSO then has its own name, colours and watermark and appears on the boards, in the department challenge, unit invites and the Mission Builder.

## Mission types, draw & teams

Officers pick one of four mission types; the server draws a random mission of that type, scaled to the participants.

| Mission type | Points (config) | Missions |
|---|---|---|
| Patrol | 60 | Beat Patrol, Business Check, Street Race Bust, Illegal Parking Patrol, Traffic Enforcement |
| Training | 100 | EVOC Course, Pursuit Sim, Stolen Vehicle Takedown |
| Investigation | 160 | Warrant Service, Manhunt, Suspicious Activity |
| Tactical | 200 | Gang Shootout, Hostage Rescue, Bomb Disposal, Armored Truck Escort, Prison Break, Drug Lab Raid, Gang Hideout Raid |

Cash per type is in Cash payouts. Custom missions join their type's pool when published.

Random draw rules (Config.Draw, Config.Limits)

- The pool is every published mission of the type open to every participant's department, supporting the unit's size, not switched off (Config.DisabledMissions or Admin UI → Missions), with at least one location on (Config.DisabledLocations is never drawn) and off cooldown for every participant. One eligible mission can repeat; none locks the card with the reason ("No Patrol missions for a unit of 3").
- No-repeat: never the mission the officer or unit last completed or abandoned in that type; with 4+ in the pool, not the last two either.
- Locations: one in use by another run is reserved; while another is free a spot is skipped when a non-participant player is within 75 m, when any of its points is within zoneClearance (200 m) of another active run's footprint (its start and every point, routes sampled every 50 m; also Cross-Department Missions), or when a participant played it in his last 2 runs of the mission (avoidLastLocations); locations used server-wide in the last hour get half weight (locationFreshness). A location within hardClearance (100 m; 0 = off) of another active run is never drawn: the draw tries the type's next mission, else refuses with "no location free".
- A mission call draws only in its area when it named one to the claimant; a county-wide call draws as the board does, then weights locations by 1 ÷ (1 + distance ÷ 2 km) from the nearest member.
- At most 12 runs active server-wide, 4 of them Tactical; at the cap the type cards show "Server busy".
- Tactical variants: hostile_waves may roll behaviour and spawn sets from the seed, and the Active Mission screen shows the intel line.
- Admin UI → Missions and Testing show each location's play count and last played date. Locations are added to a built-in through a Builder duplicate, and Config.MissionTweaks.<id>.disabledLocations (or Config.DisabledLocations) switches a built-in spot off (both survive updates).
- The mission is revealed only after accept. No reroll: abandoning, leaving the start route (while Config.Route.required), or missing the start timeout (10 min default) ends the run Abandoned with the type cooldown.

Location lints (tests)

- Zone lint (tests/zone_lint_spec.lua): every start and non-route point of a new mission's locations is at least zoneClearance (250 m for Drug Lab Raid) from every point of every other mission; a route counts by its ends. The 102 existing cross-mission pairs under 200 m are listed in tests/zone_lint_baseline.txt (warnings; the spec fails on a new pair or a longer list); no built-in location moves (that would reset its test status), and the owner checklist offers the list for a clean-up.
- Spawn lint (tests/spawn_lint_spec.lua), on the loaded built-in definitions, flat (2D): (1) no two spawn points of one run closer than 1.5 m (every key a block makes people, vehicles or objects from, as Check spawn points reads them; the escort truck at its route's first point); (2) every list has a point for each person, car or item the largest team brings at once (real CP.Scaling counts, each max applied; hostile_waves: the largest wave on the smallest `use` spawn sets; escort: one per ambush wave), no exceptions; (3) every armed point keeps the start circle plus Config.Builder.spawnMargin (CP.Builder.armedKeepOut) unless the director places it as officers come near (hostile_waves, flee_arrest scatter) or it is staged. Known cases are tests/spawn_lint_baseline.txt (26 lines); the spec fails on an unlisted case, a listed armed key coming closer, a stale line, or a longer list.
- Setup coordinates (`tests/setup_coords_spec.lua`): each shipped mission desk and downed drop-off names its source place in tests/fixtures/foreign_sites.lua on its config.lua line ('from qbx_policejob config/shared.lua:21') and is within 3 m and 1 m of height of it, 1.5 m clear of every other place, inside the map and in no other no-build zone; a desk is 1.5 m or more off its duty point and faces it. The Sandy Shores desk has no Qbox source and is listed as kept.
- Other scripts' places (tests/foreign_sites_spec.lua): no built-in start or spawn point (each block's pointKinds) lies inside the keep-out circle of a fixed place of the public Qbox and ox scripts listed in tests/fixtures/foreign_sites.lua (written by tools/gen_foreign_sites.py from clones of them; docs/OWNER_GUIDE.md 4.1), flat and within 10 m of height: 6 m round a garage, vehicle spawn or job spot, 4 m round a hospital, station or prison point, 2 m round an ox_target spot (counter, register, safe, locker, stash, door), or the script's own radius when larger, up to 10 m (a bigger area and a wall camera are only listed). No baseline: a conflict is moved.

Route to the start (Config.Route)

- At accept each participant's tablet sets a GPS route to the start, the only accepted way there. The client samples it every 50 m (GetPosAlongGpsTypeRoute) and keeps that line; every 2 s it reports the distance from it (server:routeStatus). More than 120 m off for 10 s shows a warning on the HUD and tablet; still off 30 s after leaving ends his run Abandoned (type cooldown); back within 120 m resets it; no report for 10 s counts as off route. Recalculate route (Active Mission) works up to 2 times per run, from where he is. The server also abandons him when his straight-line distance grows more than 1,000 m past his closest. The check stops at the start; the run moves to In progress when its first participant arrives. A real call ends the run anyway, without penalty. A circle start (Manhunt) routes to its centre until he is inside.
- Late partners (owner decision, lateArriveRange 150 m): once the run is In progress anyone still driving follows the action, with required on or off: within a second his route check stops (warning, countdown, drift and missing-report checks, the off_route end), his game drops the start's waypoint, pin and circle and only then gets the GPS line to the current objective. He arrives (alert suppression starts) inside the start circle or within lateArriveRange of the current objective's anchor or anything its pointer shows. The HUD, run bar and Active Mission say "Joining your partners", Set GPS and Recalculate are gone (Objective GPS works), a toast tells him. With no objective line possible (Radio Silence 'area' or 'none', markers or route off) the start's waypoint stays his guide. He gets followActionSeconds (300 s) from then to arrive, never less than his own start deadline, shown in the last 2 minutes; 0 = the start deadline only. lateArriveRange = 0: everyone keeps the route check and only the start counts.
- The start is a yellow map pin "Mission start" (Config.Markers.kinds.start, startBlip) from accept until arrival or the run's end. The accept waypoint is its GPS line; while that waypoint is gone (cleared, or his own waypoint, never touched) the pin carries the line (routeColour); Set GPS puts it back. While the route is sampled the pin carries the line as well (the only time both show). A start at least startCircleMin (200 m) wide is also drawn as a circle (areaAlpha). Radio Silence never hides it.
- Config.Route.required (true) is the owner's switch: false keeps the route set, sampled, reported, shown and recalculable and arrival counted, but drops the warning, countdown, drift check and off_route end (no type cooldown from the route); the screens show "GPS route to the start" instead of "On route" and the accept text leaves the route out. The start timeout stays. Locked at accept (run.routeRequired, sent in client:start). A test run follows its own Start route switch.

Units (Config.Units)

- Any officer or supervisor invites on-duty officers of any department into a unit of up to 4 on the Unit screen; invitees accept on their own tablet. The first inviter leads (a solo officer leads himself); a leader who leaves before accepting hands over to the longest-standing member; a unit of one dissolves. invitePolicy 'anyone' (default) or 'leader'.
- The leader picks the type; invites close then (the draw depends on size and cooldowns); every member gets the same mission. A member who leaves, goes off duty or switches job mid-run is Abandoned; the run goes on.
- Before accept only: Kick (no re-invite for 60 s; costs nothing), make leader, disband, withdraw an invite (the inviter can too, freeing the slot at once).
- Ready check: when the leader of 2+ accepts a type or claims a call, every member gets "Ready for Tactical?" (type and twists, never the mission) with a 20 s countdown on the tablet, a toast and the optional key crimsonpolice_ready. The draw runs only when all accept, after every check again; a decline or timeout cancels at no cost and names who did not answer.
- The invite list shows the nearest officers first (distance bands from server coordinates) and "Re-invite last partners". The Unit screen shows per type how many missions the unit could draw at its size and one bigger ("Investigation: 1 solo · 3 with a partner"), counts only.

Scaling by participants

The tier comes from the participants when the run moves to In progress and sets enemy numbers, strength, points and cash; it never goes up.

| Participants | Tier | Counts marked "scales" in a mission card | Armed NPC accuracy / armour | Points team multiplier | Cash multiplier |
|---|---|---|---|---|---|
| 1 | Standard | × 1.0 | base | × 1.00 | × 1.00 |
| 2 | Reinforced | × 1.25 | +5 / +10 | × 1.10 | × 1.15 |
| 3–4 | Heavy | × 1.5 | +10 / +25 | × 1.15 | × 1.30 |
| 5–6 | Major | × 2.0 | +15 / +50 | × 1.20 | × 1.50 |
| 7–8 | Critical | × 2.5 | +20 / +75 | × 1.25 | × 1.75 |

- Scaled counts round to the nearest whole number, halves up. Major and Critical exist only in Cross-Department Missions (up to 8); units stop at 4.
- Caps at any moment: 25 armed NPCs alive and 80 entities per run. Dead NPCs and wrecks are deleted after 30 s, except bodies kept for Process the scene (its body limit, oldest first). The next wave waits for room; counts are never cut to fit the caps, only by a shrinking team or a fight's leaveOutAfter (Suspect behaviour).
- Cross-department bonus: participants from 2+ departments earn × 1.10 points on top of the team multiplier.

When someone leaves mid-run (Config.Rescale)

- Waves, vehicles and NPCs not yet spawned use the new team's tier (counts, accuracy, armour); spawned NPCs stay; a partly spawned wave gets the new total and spawns only what is missing.
- The points and cash tier drops only when the leave could boost the run:

| Why they left (end_reason) | NPCs not yet spawned | Points and cash tier |
|---|---|---|
| Real call, force recall or went down (real_call, force_recall, downed) | Shrink to the team that's left | Stays as it was; if the leave later becomes real_call_cancelled, it drops then |
| Quit, off duty, job change, suspended, disconnected, or removed by the idle check (quit, off_duty, job_change, suspended, disconnected, idle) | Shrink to the team that's left | Drops to the team that's left |

- Nobody joins after the start. The HUD shows the new tier and the result screen the tier used for points and cash.

Cross-Department Missions (Config.CrossDept)

- A supervisor or admin launches one mission open to every department and supporting 2+ officers (Supervisor UI → Mission List, Admin UI → Missions); never the Weekly Boss. One active server-wide; a launch at most every 30 minutes (cooldown).
- Board lock: every on-duty officer is notified and sees only its card; the server refuses every other new mission, the Weekly Boss included; runs already accepted finish normally.
- Join: any department, up to 8; joining closes at Start now or 5 minutes after launch; 2 needed to start. When full, a waitlist; a freed place goes to its first. A participant may leave before the start at no cost; a supervisor with launchCrossDept may remove a joiner before the start (reason, audited).
- The route rules apply; the tier is set at In progress; points, scaling and cash as any run, with the cross-department bonus when 2+ departments joined.
- The lock lifts when the run is Completed. A failed or emptied run leaves the operation active for any supervisor to relaunch or cancel; it auto-cancels after 30 minutes with no run in progress.
- They ignore type and mission cooldowns, the no-repeat rule, the hourly cap and the run cap, and never have a twist.

## Mission catalog

v2 ships 18 missions plus the Weekly Boss, one file each in missions/builtin/. This table is the summary; each mission's full behaviour is in its file (Mission cards links them).

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
| Illegal Parking Patrol | parking_patrol | Patrol | 1 | ★ | 10 min | — |
| Traffic Enforcement | traffic_enforcement | Patrol | 1–2 | ★★ | 12 min | Violators (1 solo, 2 with two officers); occupants per stopped car (max 3) |
| Suspicious Activity | suspicious_activity | Investigation | 1–2 | ★★ | 10 min | Subjects (max 3) |
| Drug Lab Raid | drug_lab_raid | Tactical | 2–4 | ★★★ | 12 min | Hostiles, cooks (max 3), stashes (max 4) |
| Gang Hideout Raid | gang_hideout_raid | Tactical | 2–4 | ★★★ | 12 min | Hostiles, runners (max 4), caches (max 2) |
| Weekly Boss: Kingpin | weekly_boss_kingpin | Tactical (event card) | 1–4 | ★★★ | 15 min | Hostiles |

The officer counts are for normal runs. As a Cross-Department Mission, any mission that supports 2 or more officers takes up to 8.

Mission definition fields: id, label, description (shown on the Active Mission screen after the draw), type, departments (empty = every department), minOfficers, maxOfficers, difficulty (1–3), timeLimit (seconds after the run moves to In progress), startTimeout (seconds to reach the start; default Config.Limits.startTimeout), cooldown (per officer, seconds), locations, objectives (blocks, in order; each may set minSeconds, its minimum believable time, and presenceRange; otherwise the block's defaults apply), scaling (which counts scale), items (optional ox_inventory items given at the start and removed at the end), bonuses, penalties, vehiclePenalties (default true; false turns off the heavy vehicle-damage penalty where contact or gunfire damage is expected), quietPatrol (true = lights and siren used after the first participant arrives at the start cost −10, personal; the drive to the start never counts; replaces the hard-coded Beat Patrol / Business Check list), decisions (optional overrides of Config.Decisions for this mission). Every objective of a block that arrests may set custody ('cuff' or 'handover'). There is no payout field, no reward field and no grade requirement. Every mission file, built-in or custom, contains exactly one RegisterMission({ ... }) call (see Example files).

Design rules

- NPCs only; nothing a non-participant can take or interact with. NPCs never drop weapons or loot when they die (SetPedDropsWeaponsWhenDead(ped, false)), and ox_target options only appear for participants. Live crimes and volunteer suspects: ARCHITECTURE sections 5.45-5.47.

- Mission NPCs and vehicles are networked entities created by the server (OneSync), so every participant sees the same ones. The run host's client runs their AI, and the server deletes everything when the run ends for any reason, even if no participant is left.

- From the moment a participant reaches the mission start they carry the alert-suppression flag, so their mission combat creates no SC-Dispatch or SC-Ambulance alerts (see Real calls, alerts & downed officers).

- Built-in missions ship with at least 5 locations (3 for Armored Truck Escort routes, EVOC layouts and Kingpin compounds). Custom missions need at least 1 (Config.Builder.minLocations; owner decision: one location is enough, and the Locations step shows "3 or more locations feel less repetitive" as a hint, not an error). An edited built-in keeps at least 3 (Config.Builder.minLocationsOverride): built-in missions keep their own locations.

- NPC arrests use Crimson-Police's own ox_target actions (Cuff suspect, Detain, and the custody chain). They never call sc-police's player cuffing, escort, search, impound or jail.

- Crimson-Police never triggers sc-police's impound, and sc-police's /imp is never a lawful way to finish a mission. A police:server:Impound on a run vehicle is only listened to (see Police actions & decisions → Impound).

- Every mission vehicle gets a plate in the reserved pattern (Config.Custody.plates) that no player owns, checked read-only against player_vehicles, so nothing done to a mission car can reach a player's own car.

- People and cars in a mission never hand anything to a player: seized items and evidence are virtual, shown on the tablet.

- Every objective is marked on the map as it comes up (Config.Markers; each card's Marking line says how). Once an officer is at the action, the HUD names what his objective blip leads to and how far it is, under the objectives ("Destination · 1.2 km", to a circle's edge, "You are in the area" inside it; Config.Markers.hudLine): only for what his map shows (under Radio Silence no distance to a suspect or car it hides) and never while he still drives to the start. The Active Mission screen's Objective GPS button (Config.Markers.objectiveGps) puts a map waypoint on it: the waypoint is then his one GPS line (the objective's own line goes off), it follows a moving objective (a car, a suspect, the next nearest door) while it is still his, and it goes when the objective ends or the run ends; a waypoint he sets himself is never moved or removed. It is refused while he still drives to the start (Set GPS is his line there) and while Radio Silence hides the objective's line ('area' or 'none').

## Mission cards

Each mission's full behaviour (basics, locations, start, spawns, marking, objectives, bonuses and penalties) is the header and the objectives of its own file in missions/builtin/; the Weekly Boss keeps its card here because its event rules are not in the file. Every card also gets the common bonuses and penalties in Scoring unless it says otherwise, every count marked "scales" is multiplied by the run's tier, and the run's end removes everything the card spawned (NPCs, vehicles, props, target zones, blips; NPC traffic restored). The location lists are in each mission's file.

Locations of a new built-in come from GTA V vehicle nodes and known base-game places and pass the loader's guardrails (no-build zones, 100 m between locations, spawns 30 m from the start) and the cross-mission zone lint (start and non-route points 200 m from every point of every other mission, 250 m for Drug Lab Raid; routes by their ends only; see Random draw rules); a Builder duplicate of each must validate and publish. Each shows "Not tested" in Admin UI → Testing until an admin passes it at the tier its maxOfficers reaches.

Marking terms used below (Config.Markers): anything too far for an officer's game (OneSync streams 424 m) shows where the server has it, so it stays on every map at any distance.
- Checkpoints: the current one is a numbered yellow blip with the block's GPS line (Config.Markers.routeColour) until cleared, the next a smaller numbered yellow blip; an officer still driving to the start or with his own waypoint gets no checkpoint line; under Radio Silence ('area') only the current one shows, without a line, and the HUD names its street.
- The fight circle: a red circle with a skull, "Hostiles", round the fight's spawn points (15 m past the farthest, the boss's spot included), with the GPS line to its centre until you are inside it; each hostile a red dot.
- Chase marking: a runner is an orange blip while he runs and red once he fights or gives up, with the GPS line to the nearest.
- The scene: a yellow map pin "Scene" with the line, until it is processed.

- Beat Patrol: [missions/builtin/beat_patrol.lua](../../Crimson-Police/missions/builtin/beat_patrol.lua)
- Business Check: [missions/builtin/business_check.lua](../../Crimson-Police/missions/builtin/business_check.lua)
- Street Race Bust: [missions/builtin/street_race_bust.lua](../../Crimson-Police/missions/builtin/street_race_bust.lua)
- EVOC Course: [missions/builtin/evoc_course.lua](../../Crimson-Police/missions/builtin/evoc_course.lua)
- Pursuit Sim: [missions/builtin/pursuit_sim.lua](../../Crimson-Police/missions/builtin/pursuit_sim.lua)
- Stolen Vehicle Takedown: [missions/builtin/stolen_vehicle_takedown.lua](../../Crimson-Police/missions/builtin/stolen_vehicle_takedown.lua)
- Warrant Service: [missions/builtin/warrant_service.lua](../../Crimson-Police/missions/builtin/warrant_service.lua)
- Manhunt: [missions/builtin/manhunt.lua](../../Crimson-Police/missions/builtin/manhunt.lua)
- Gang Shootout: [missions/builtin/gang_shootout.lua](../../Crimson-Police/missions/builtin/gang_shootout.lua)
- Hostage Rescue: [missions/builtin/hostage_rescue.lua](../../Crimson-Police/missions/builtin/hostage_rescue.lua)
- Bomb Disposal: [missions/builtin/bomb_disposal.lua](../../Crimson-Police/missions/builtin/bomb_disposal.lua)
- Armored Truck Escort: [missions/builtin/armored_truck_escort.lua](../../Crimson-Police/missions/builtin/armored_truck_escort.lua)
- Prison Break: [missions/builtin/prison_break.lua](../../Crimson-Police/missions/builtin/prison_break.lua)
- Illegal Parking Patrol: [missions/builtin/parking_patrol.lua](../../Crimson-Police/missions/builtin/parking_patrol.lua)
- Traffic Enforcement: [missions/builtin/traffic_enforcement.lua](../../Crimson-Police/missions/builtin/traffic_enforcement.lua)
- Suspicious Activity: [missions/builtin/suspicious_activity.lua](../../Crimson-Police/missions/builtin/suspicious_activity.lua)
- Drug Lab Raid: [missions/builtin/drug_lab_raid.lua](../../Crimson-Police/missions/builtin/drug_lab_raid.lua)
- Gang Hideout Raid: [missions/builtin/gang_hideout_raid.lua](../../Crimson-Police/missions/builtin/gang_hideout_raid.lua)

### Weekly Boss: Kingpin · weekly_boss_kingpin
- Basics: Tactical event card · 1–4 officers · ★★★ · time limit 15 min · once per officer per week, Friday–Sunday (server time); cannot be launched as a Cross-Department Mission
- Locations: 3+ compounds, each with 16+ hostile spawn points
- Start: within 100 m of the compound
- Spawns: 30 hostiles (scales) in 4 waves of 8 / 8 / 7 / 7, each scaled the same way, then the Kingpin after the last wave. Pistols, heavy pistols and shotguns; base accuracy 30 and armour 25, plus the tier's increase. The Kingpin has armour 100, health 400 and a heavy pistol, and does not scale
- Marking: during the fight the fight circle
- Marking: "Secure the scene" a numbered yellow blip with the GPS line
- Objectives: 1) neutralise every hostile; 2) neutralise the Kingpin; 3) ox_target "Secure the scene" (8 s)
- Scales: hostiles
- Fail if: every participant is downed, or the time limit runs out
- Points and cash: 500 points (Config.Events.weeklyBoss.points) instead of the type points; base payout Config.Events.weeklyBoss.payout ($2,500) until an admin sets a mission payout; counts as Tactical for the leaderboards, the 4-Tactical run cap and the hourly cap, never has a twist, and is accepted from its card with the key weekly_boss. Its runs are stored with mission_type = 'tactical'. Abandoning it (except for a real call, force recall or cancel) uses up that week's attempt and puts no type on cooldown
- Bonuses: Kingpin arrested alive +50; no participant downed +10% of points
- Penalties: vehiclePenalties = false (vehicles take gunfire)

## Special events

Three events rotate on top of the normal missions to keep the board fresh.

| Event | How it works | Limits |
|---|---|---|
| Type of the Day | One mission type, picked at the daily reset (Config.Time.resetHour, server time) with a random seed made from the date, so a restart keeps the same type, earns double points (applied after the 2× points cap). A department whose supervisor picked a type the day before (typeOfTheDay Mission control) uses that type instead for its own officers, except the setter and a unit he is in | Points only; cash is not doubled |
| Twists (modifiers) | The officers choose them when they take a mission: on the accept step of the Mission Board or of a mission call claim (the unit leader decides for the unit; the members see them on the ready check and on the Active Mission screen). Armored Hostiles (+50 armour on armed NPCs; offered only for a type with a mission that spawns armed NPCs), Time Crunch (time limit cut by 25%; only with a time limit) or Radio Silence (after the start the map shows what Config.Markers.radioSilence keeps: 'area' (shipped) each objective's circle or its one point (of several points or devices only the officer's nearest) without a GPS line and without blips on people or cars, 'none' no blips for mission NPCs or objectives, 'full' everything; the Active Mission screen shows only street and zone names and says which of the three applies; the start route, the prisoner van and the tow truck still show). The mission is still drawn at random after the accept: a chosen twist the drawn mission has no use for (Armored Hostiles on a mission without armed NPCs) is dropped without its bonus, and the officers are told. Random twists are off as shipped (Config.Events.modifierChance = 0); turned on, a random one only adds to the chosen ones | Each twist adds its own bonus (Config.Events.twists: Armored Hostiles and Radio Silence +25% of P and × 1.25 cash, Time Crunch +20% of P and × 1.20 cash); several stack: the points shares add up, the cash multipliers multiply, capped at +70% of P (twistMaxPoints) and × 1.95 (twistMaxCash). Paid only for a Completed run; never on Cross-Department Missions, the Weekly Boss or test runs |
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
| Real call, a supervisor's force recall, or the run was cancelled (admin End run or End test, a cancelled Cross-Department Mission, a voided volunteer case) | real_call, force_recall, cancelled | Abandoned | No |
| Went down | downed | Failed (partial points, no cash) | Yes, so going down can't be used to reroll |
| Disconnected | disconnected | Failed (partial points, no cash) | Yes, so disconnecting can't be used to reroll (the Weekly Boss: no type cooldown; its mission cooldown starts and that week's attempt is spent) |
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

## Dispatch (mission calls)

Mission calls are the tablet's own call board (all numbers in Config.MissionCalls): the server posts short NPC incidents every on-duty officer sees, and the first unit to claim one gets a random mission of that type starting in the call's area. They never touch SC-Dispatch, and real calls always come first.

What a call shows

| Field | Example | Notes |
|---|---|---|
| Code | MC-0427 | Numbered per day |
| Title | "Armed persons reported" | Drawn at posting from 5–8 radio lines per type (mc.title.<type>.<n>, titles) that fit every mission of the type; never a mission name. After a claim wins, the card and Active Mission header show the drawn mission's caller report |
| Type | Tactical | The type the draw uses; Type of the Day is tagged |
| Priority | P1 | From the type: Tactical P1, Investigation P2, Patrol P3 |
| Area | South Los Santos | Per viewer: shown only when his eligible pool there (after unit size, no-repeat, cooldowns, daily limits) holds at least minMissionsPerArea (2) missions and minLocationsPerArea (3) locations; otherwise "County-wide" and his claim draws as the board does. Never the mission |
| Distance | area ~1.4 km | From server coordinates to the area's centre (county-wide: the nearest eligible area). After a win the toast gives the real distance and the response target |
| Offer | 2:40 left | Counts down from offerTime (180 s) |
| Crew | Solo or unit / Needs a unit of 2+ | From the viewer's eligible pool |
| Pay | $250 · 60 pts · +6 rapid response | The type's board range for his unit size, plus rapid response (none on paged or staff calls) |
| Status | Ready · Nearest units first 0:12 · Locked (reason) · Confirming: 2L-14's unit (0:14) · Claimed by 2L-14 (SAST) · Re-dispatched · Lapsed | Per viewer; the winning unit gets "Your unit took MC-0427: Ready?" (the ready check) |

First to claim

- Only a unit leader or solo officer claims, with exactly the Mission Board accept checks (duty, suspension, leader, not on a run or a real call, not in Crimson-Arena, no Cross-Department Mission, caps, every member's cooldowns, run caps) plus an eligible mission of the type in the area. A failed check shows its reason ("Tactical on cooldown for 3:12 (2L-14)").
- Every valid claim within claimWindowMs (1.5 s; 0 = first click) of the first is ranked: nearest member to the area's centre, then fewer claims in the last hour, then earliest. Losers see "Claimed by 2L-14 (SAST), a closer unit" (or ", fewer recent calls" / ", claimed first").
- For the first priorityWindow (15 s) only units within priorityRadius (1,500 m) can claim, if one was idle at posting ("Nearest units first").
- The winner goes through the normal accept: ready check, invites close, the draw in the area (every draw rule), the run and start route; the mission is revealed only then. A declined or timed-out ready check reopens the call for its remaining time, tries the next-ranked claim, and bars that unit from the call; no cooldowns.
- A claimed call counts as that unit's accepted type for every rule (cooldowns, caps, abandoning, the route, real calls); only rapid response differs.

How calls are posted

- Every 10 s; never while a Cross-Department Mission is active (open calls are withdrawn at its launch) and never a call no idle unit could claim. Idle = on duty, not on a run or a real call, not in Crimson-Arena, not suspended.
- At most one open call per unitsPerCall (2) idle units, at least 1 while anyone is idle, never more than maxOpen (4), one new call every spawnEvery (60–150 s, random). Type by weight (Patrol 5, Investigation 3, Tactical 2); Training and the Weekly Boss never; a type at its run cap is skipped. Area weighted towards idle units, never the same type and area as another open call. Nothing is sent before posting and the mission is chosen only when a claim wins.
- Cost: each on-duty officer's eligibility is kept in memory (filled from cp_mission_runs on duty, updated on row:settled, cooldown and duty changes); no query per call or viewer. Per-viewer cards (DispatchView) are built only for open tablets; others get the cached claimable count. Budget: under 0.25 ms of server time per tick at 30 officers, both storage modes.

Scaling and rapid response

- A call has no difficulty of its own: the run scales like any run, and the card shows the viewer's unit size's cash and points.
- Rapid response (server-posted calls only): a participant reaching the start within the response target earns +10% of P (points only, personal, inside the 2P cap). The target is set at the win: the nearest member's straight-line distance to the drawn start ÷ 20 m/s + 45 s (rapidResponse), counting down on Active Mission. A quietPatrol penalty counts only after arrival, so hurrying is never penalised.

When a call ends

| Status | When | What happens |
|---|---|---|
| Lapsed | Nobody claimed it within offerTime | Shown as "Lapsed" for 10 seconds, then removed. It has no effect on anyone |
| Withdrawn | A supervisor withdrew it, or a Cross-Department Mission launched | Removed at once, with the reason |
| Claimed | A claim won | Closed with the run's outcome (completed, failed or abandoned) when the run ends |
| Re-dispatched | The claimed run ended before any participant reached the start (quit, off_route, start_timeout, idle, real_call, force_recall) | Reopens once for 120 seconds, tagged "Re-dispatched". Members of the old claim can't claim it again, and their normal abandon rules and cooldowns still apply |

Mission Board, real calls and live crimes

- The Mission Board is unchanged and always works; calls are a second way in, and taking a type on the board does not touch open calls. The board links "2 mission calls open" to Dispatch. The Weekly Boss and Cross-Department Missions are board-only; during an operation Dispatch shows its banner.
- Mission calls never reach SC-Dispatch (F10 panel, MDT, notifications, unit status), and its dispatcher mode (AssignedOnlyAlerts) has no effect on them. An officer on a real call can't claim ("On a call"), gets no toasts, and a real call still ends any run at once with no penalty or cooldown. Dispatch shows a read-only strip "SC-Dispatch: 3 active real calls (1 Priority 1) — real calls come first", counted from mdt_dispatch (NPC calls excluded) every 20 s, hidden when the lookup fails.
- LIVE calls (Config.RealPlayers.liveCrime, off) mirror a real SC-Dispatch crime with real-player suspects: claiming opens the live case at its reported place, with no draw, twists or rapid response, and is never re-dispatched. Its claim, ready check, cooldown and anti-farm rules (Config.RealPlayers.liveCrime, Config.RealPlayers), backup joining, the officers' Live case card and result outcomes, and the staff Real suspects screen with its tools (block pair, exclude, suspend, lift, clear strikes) are in docs/dev/ARCHITECTURE.md §5.45–5.47 and docs/OWNER_GUIDE.md 6. A staff member who was a suspect of a case counts as taking part in its run: he never reviews or reads it.

Supervisor and admin controls (Config.Permissions.supervisor.missionCalls)

| Action | Who | Where | What it does |
|---|---|---|---|
| View calls | Supervisor (all open calls; claims involving their department), Admin | Supervisor UI → Live Missions → Mission calls; Admin UI → Missions | Open, claimed and lapsed calls today, claimants, time to claim, response times |
| Withdraw a call | Supervisor, Admin | Same | Removes an open call; reason required |
| Page a unit | Supervisor, Admin | Same | Posts a call of a chosen type and area offered only to one unit for 30 seconds (Config.MissionCalls.pageTime), then to everyone; ignoring it costs nothing |
| Create a call | Supervisor, Admin | Same; /CrimsonPoliceAdmin missioncall <type> [area] | Posts a call of that type and area now; at most one every 2 minutes per supervisor (staffCooldown, or his department's staffCallWait Mission control) |

- Staff calls can't be used for oneself: Page is refused for the issuer's own unit (err.mc_page_self); the issuer's citizenid is checked against every member of a claiming unit for the whole offer (err.mc_own_call); paged and created calls never earn rapid response and the mission is still drawn at random. Every staff action is audited (category operations) and posted to cp_webhook_operations.

Screens and alerts

- Officer UI → Dispatch, after Mission Board: cards by priority, then age; filters All · Claimable · Near me; the real-call strip; notices for "On a run", "On a call" and "Cross-Department Mission active"; "Recent calls" (the last 5, who took each and how it ended). Claim opens a confirm ("The mission is drawn at random and revealed after you claim. Abandoning puts Tactical on cooldown.") with the type's twists, as on the board.
- A new call plays a tone and shows a toast to officers who could claim it, unless muted (per player on Dispatch, saved in cp_officers.calls_muted). The sidebar counts claimable calls, Home shows "Mission calls open: 2", and crimsonpolice_dispatch (Config.Tablet.dispatchKey, unbound) opens the tablet on Dispatch.
- Profile & History shows calls answered and the average response time; boards can rank by mission calls; goals and bounties can count them.

## Police actions & decisions

Some missions hide the story of a person or car (a parked car, a driver at a stop, someone behind a shop). When the objective starts the server rolls the truth; officers find it out through police actions, then decide each person's and car's disposition. The server grades every decision against the truth, fairly: nobody is penalised for what no lawful action could have found, and Best needs the deciding fact found lawfully. Wrong choices cost points; releasing someone known to be dangerous fails the case, after a warning on the tablet.

Contacts

- A contact is a person or car a field_contact objective owns: parked cars (Illegal Parking Patrol), people at a scene (Suspicious Activity), and the car and occupants of a stop (Traffic Enforcement, Stolen Vehicle Takedown).
- The truth stays on the server (run.entities[netId].truth and armedTruth): never in a state bag, client event, NUI message or the ped. Every contact spawns unarmed with no combat settings in its cp bag; the run host is told only the behaviour to act out, when it starts (walk_away, flee_on_approach, flee_on_order, tell_then_draw); the weapon and combat settings are given at the draw, after the tell. maxArmedAlive and the builder's armed budget count armedTruth.
- A fact is revealed only by a validated action, only to that run's participants, and is known to the run from then; for knowing errors it is known to one officer from when the server sent it to him.
- Active Mission → Contact panel: each person (A, B, C) and car with its facts, who found them and when, a "Not checked yet" list (ID, plate, frisk, inside, search) of the actions still open, "Not detained: free to leave" in a consensual contact, and the disposition buttons. The HUD shows the newest fact.
- A pursuit with handoff = 'contact' hands the stopped car and its people to the field_contact objective (CP.Runs.adopt): their deaths, cuffs and custody events go to it from then on, and the host runs their AI through field_contact.

Where the actions are

| Target | How officers reach it |
|---|---|
| A person on foot | ox_target on the ped |
| A person seated in a car | ox_target on that seat's door (door_dside_f, door_pside_f, door_dside_r, door_pside_r); the server finds him with GetPedInVehicleSeat |
| A car | ox_target on the car |
| No world target | HUD actions on crimsonpolice_contact (Config.Tablet.contactKey, unbound by default) and Contact panel buttons: Run plate from a vehicle (nearest contact car within 20 m in front), Place in vehicle, Hand over to transport, Escort on/off |

The server resolves the target from server-side coordinates; the client only names the action. A disposition that would be a knowing error never runs from ox_target: it opens the Crimson-Police confirm.

Pullover

- At a stop the officer first observes the violation when the mission asks (pace a speeder or follow a reckless driver), then turns the lights on within 60 m; the car rolls yield, flee or fight (Suspect behaviour). A yielding car's people stay seated until Order out, or react by demeanour. A car stopped by force (PIT, box-in) hands its people over as Evading; anyone who ran must be caught and cuffed first.
- The Contact panel opens as soon as the car is stopped; the driver's door offers Talk / Check ID and the car Run plate.

Police actions (participants only; each has an ox_lib progress bar, and cancelling counts for nothing)

| Action | Target | Time | What it reveals or does |
|---|---|---|---|
| Talk / Check ID | A person who is stopped, compliant or detained (seated: at their door) | 4 s | Name, licence status, warrant check (active warrant or clear), odour of alcohol or cannabis, an admission (20% of guilty subjects), and whether they consent to a vehicle search |
| Frisk | A person within 1.5 m | 4 s | Weapons only. A pat-down for officer safety is always lawful |
| Detain | A person who is stopped or compliant | 3 s | Cuffs them for safety. Not an arrest; they can still be released |
| Search person | A detained or arrested person | 4 s | Everything on the person (contraband, tools, cash, ID) |
| Look inside | A car, at a window | 2 s | Items in plain view |
| Run plate | A car: on foot beside it (ox_target), or from the driver seat of a vehicle within 20 m (HUD action) | 3 s | Registration: valid, expired or STOLEN; the registered owner's warrant |
| Inspect | A parked car | 3 s | The posted rule for that spot, permit, meter and how long it has been parked |
| Order out | A car with people in it | 2 s | Everyone gets out and stands by the car, or reacts by demeanour |
| Search vehicle | A car | 8 s | Contraband, weapons, tools, evidence. Needs probable cause or consent |
| Verbal warning | A person (stops only) | 2 s | Disposition Warn |
| Write citation | A person, or a parked car's windscreen | 6 s | Disposition Cite; the officer picks the offence from the list on the tablet or HUD |
| Release | A person | 2 s | Disposition Release; uncuffs them if detained; they walk or drive off and are removed 30 s later |
| Arrest | A detained person | — | Disposition Arrest; starts the custody chain |
| Impound | A car | 10 s | Disposition Impound; a Crimson-Police tow truck collects it |
| No action | A car | 1 s | Disposition No action |

Checks: every action has a begin and a finish. The server records the begin, checks the officer's reach with server-side coordinates at both ends and the elapsed time against Config.Custody.times (minus 0.5 s); actions of 3 s or more are sampled every second. A finish without a begin, or too early, is refused. The Contact panel's disposition buttons (server:contactDecide) run no bar: the server checks a live run, an arrived active participant on duty and not in Crimson-Arena, the contact's state, and 25 m reach; a knowing error returns the case-fail confirm. The ox_target options for the same dispositions run the bars above.

Probable cause

- A vehicle search is lawful with any one of: an item seen through the window, an odour, an admission, a weapon found in a frisk, an occupant arrested, a stolen plate (an impounded car gets an inventory search), or consent (clean people 60%, guilty 15%).
- Without one: −15 for the searcher (unlawful_search, personal), and what it found is inadmissible: shown struck through, never counted toward a grade (an arrest resting only on it is Acceptable, never Best).
- A frisk is always lawful but finds weapons only; a full search needs the person detained or arrested.

Lawful ways to each truth (cues rolled with the truth, from the seed)

| Truth | Lawful ways to find it |
|---|---|
| Active warrant | Talk / Check ID, always; Run plate shows the registered owner's warrant |
| Armed, on the person | Frisk, always |
| Armed, in the car | Look inside (plain-view cue 40%), then Search vehicle with cause |
| Narcotics or tools, on the person | Detain, then Search person, always |
| Narcotics or tools, in the car (50% of guilty people with a car) | Look inside (plain-view cue 40%), Talk (odour 30%, admission 20%, consent 15%), then Search vehicle |
| Intoxicated driver | Talk (odour), always |
| Suspended licence, minor offence | Talk / Check ID, always; an observed violation (pace or follow) |
| Stolen car | Run plate, always |
| Parking violation | Inspect, always |
| Car holds evidence | As narcotics in the car |

Grading rules

- Best only when the deciding fact was revealed lawfully. An Arrest with no lawful supporting fact grades Acceptable at best, and is wrongful_arrest (−25) for a clean or minor truth.
- When no lawful path to a truth was ever open for that contact (the server tracks which cues and actions existed), Release or No action grades Acceptable; the debrief says "Not discoverable lawfully".
- An observed violation (pace or follow evidence the server recorded) raises the driver's truth to at least Minor: Cite = Best, Warn = Acceptable, Release = missed_offence. Passengers are unaffected.
- Running on foot from a lawful detention or order (a stop, Detain, Order out, a frisk) makes the person Evading in every mode (Arrest = Best, Cite = Acceptable); walking away from a consensual contact changes nothing.
- One act, one reward: a person caught after running earns subject_alive once, and his Arrest is recorded Best with 0 points. A disposition decided by a fact the mission gave from the start (`revealed`, e.g. Stolen Vehicle Takedown's stolen car) is graded but earns no correct_disposition.

Dispositions and grades

| Truth (hidden) | Best | Also acceptable | Wrong choices and their cost |
|---|---|---|---|
| Clean | Release | Warn | Cite −5 (wrong_citation), Arrest −25 (wrongful_arrest) |
| Minor offence (expired licence, open container, loitering, or a driver whose violation was observed) | Cite | Warn | Release −5 (missed_offence), Arrest −25 (wrongful_arrest) |
| Suspended licence (driver) | Cite, and the car impounded | Cite, and the car left legally parked | Release them to drive on −5 (missed_offence) |
| Active warrant | Arrest | — | Release: fails the case once the warrant was known to the decider; otherwise −15 (missed_arrest) |
| Armed (illegal firearm) | Arrest | — | Release: fails the case once the weapon was known to the decider; otherwise −15 (missed_arrest), or Acceptable when it was not discoverable lawfully |
| Narcotics or burglary tools | Arrest | Cite | Release −15 when found lawfully (missed_arrest); −5 (missed_offence) when a lawful path was open but not taken; Acceptable when none was |
| Intoxicated driver | Arrest | — | Release or Cite −15 (missed_arrest) |
| Evading (ran from a lawful detention or order, or a stolen car's occupant) | Arrest | Cite | Release −15 (missed_arrest) |
| Car: legal | No action | — | Cite −5 (wrong_citation), Impound −15 (wrongful_impound) |
| Car: meter or permit violation | Cite | — | No action −5 (missed_offence), Impound −15 (wrongful_impound) |
| Car: blocking (hydrant, fire lane, loading zone, no parking) | Impound | Cite | No action −5 (missed_offence) |
| Car: stolen | Impound | — | No action or Cite: fails the case once the plate result was known to the decider; otherwise −10 (missed_impound) |
| Car: holds evidence found lawfully | Impound | — | No action −10 (missed_impound) |
| Car: left unattended by an arrest | Impound | No action (left legally parked) | — |

- Each Best decision earns +10 (correct_disposition, personal); Acceptable earns and costs nothing.
- Knowing errors fail the case; missed procedure costs points. A case fails only when someone releases a person, or a stolen car, after the dangerous fact reached that officer (sent to him before his bar or button press began), and only after he confirmed "Known: active warrant. Releasing will fail the case for the unit." A partner's fact arriving mid-bar makes it an unknowing mistake. Every other wrong decision costs only its officer; a failed case is shared by everyone (Config.Decisions).
- A contact still undecided when the objective ends counts as missed (−5), never a fail.
- Procedure: +10 once per officer (procedure_complete) when everyone he arrested was ID-checked and searched before transport; handing an armed person to transport unsearched: −10 (unsearched_transport).
- Excessive force: a melee or taser hit on a detained, escorted, seated or compliant person costs −10 (excessive_force, personal, at most once per person per 10 s). Detection is best-effort (weaponDamageEvent, the health-drop fallback, and `stun_hit { netId }` telemetry accepted only when it matches a ragdoll or state change seen within 1 s), so it stays a small penalty. Shooting them is shot_surrendered (−20); killing them fails the mission.
- A mission file may make a decision stricter (e.g. `decisions = { wrongfulArrest = 'fail' }`), within the builder's caps.

Custody chain (custody = 'handover'; custody = 'cuff' ends the arrest at the cuff)

- Cuff suspect or Detain → Arrest → Search person → Escort (walks beside the officer; contact key toggles) → Place in vehicle (rear seat of a vehicle that officer drove this run, within 5 m) → Hand over to transport (at the van).
- At the run's first arrest a prisoner van with an NPC driver drives in and parks within 60 m of the scene (or at the location's transport point). Hand over (4 s at the rear doors) moves everyone that officer escorts or has seated within 20 m into the van. It stays until the calling objective ends, then leaves after Config.Custody.transport.leaveAfter; requestTransport sends it again for a later arrest.
- An arrest counts when the person is handed over; an escorted, seated or vanned person can't escape.

Service vehicles (transport van, tow truck, coroner van)

- The driving client is the participant nearest the scene, else the host. It proposes a road point 150–250 m away; the server checks it is inside spawnDistance and not within Config.Custody.serviceClearance (30 m) of any player, spawns the vehicle (locked, reserved plate) and hands its AI to that client, which drives, parks and, for the tow truck, takes control of flatbed and car and loads it. If that client leaves, dies or goes more than 250 m away, the AI moves to the next nearest participant.
- A van not parked within Config.Custody.serviceTimeout (60 s) is placed at its parking point (transport or coroner point, else the scene), out of every participant's view and only while no player is within serviceClearance; a late van whose point an officer stands on drives on until he steps away; a van with no road point comes to a road point beside the scene (serviceClearance to +40 m, server-checked) or waits. A placed van waits frozen for the placer (Config.Spawning.place). A tow truck with no road point in time is never made, and a tow that has not loaded in time fades the car out as impounded.
- The van and tow truck show on every run officer's map (Config.Markers.parts.prisonerVan / towTruck, on by default: "Prisoner transport", "Tow truck", blue; an officer the part's rules leave out gets none) from appearing to leaving, in every Radio Silence mode, never with a GPS line; sent when their status changes, followed once near enough; late partners get them too. The coroner van is unmarked.

Impound

- Crimson-Police's Impound is the only lawful impound: a flatbed tow truck with an NPC driver loads the car (Config.Custody.tow.enabled = false: the car fades out). It counts as impounded, never as wrecked or lost.
- sc-police's /imp and /depot are never triggered by Crimson-Police and must not be used on mission cars. A police:server:Impound on a run vehicle sent by a participant counts as removed (objective fails "Mission vehicle removed", run flagged sc_impound with his name); sent by anyone else, or a car vanishing unrecorded, ends the run not counted (vehicle_removed_external: no points, cash, cooldown or abandon penalty) and the sender goes to the audit log and admin webhook. A pursuit never counts a removed car as stopped or awards vehicle_stopped_fast for it.
- Every mission plate uses the reserved pattern (Config.Custody.plates), rerolled when player_vehicles has it, so sc-police's plate UPDATE can never reach a player's car.

Process the scene (coroner)

- A process_scene mission keeps the bodies of NPCs who die in the run (up to its body limit, oldest deleted first) instead of deleting them after 30 s. Each body: Photograph & tag (5 s), Bag body (6 s; a body-bag prop). Then Release to coroner (8 s) at the coroner van, or at the scene marker when the van is off.
- No bodies: the objective completes at once and everyone earns +15 (all_taken_alive). Processing earns nothing, so killing never pays more than arresting. The fast clock stops when it starts and the time limit grows by 60 s plus 20 s per body. No SC-Dispatch or SC-Ambulance call.

Debrief, disputes and items

- The result screen and Profile & History list every decision: contact, choice, truth, facts known then, whether it was discoverable lawfully, who decided, the grade. A case failed by a decision can be disputed within 48 hours; the admin sees when each fact reached the decider.
- Config.Custody.handcuffsItem = 'handcuffs' makes Detain and Cuff suspect need that item (checked server-side, never used or taken: sc-police's handcuffs cuff the nearest player). Evidence is virtual; Config.Custody.evidenceItem (off) hands one tagged evidence bag for the run, removed at the end.

All numbers are in Config.Custody and Config.Decisions.

## Suspect behaviour

Every person in a mission gets a demeanour at spawn, rolled by the server from the run's seed (every participant sees the same behaviour; tests are repeatable). It stays on the server with the truth: the run host is told only what to act out when it starts (see Police actions & decisions → Contacts), and the Contact panel's hint names only a tell someone has already seen.

| Demeanour | What they do |
|---|---|
| Compliant | Stops when approached, answers and follows orders |
| Nervous | Complies but fidgets; 15% run when ordered out of a car or frisked (then Evading) |
| Evasive | Walks away when an officer comes within the approach distance (lawful while consensual); stops when aimed at, when an officer stays within 3 m for 3 s, or when stunned |
| Hostile | Armed people only: shows a tell, then draws and fights |
| Runner | Runs on foot as soon as an officer is within the approach distance (flee_arrest give-up and escape rules; he tires: Config.Flee) |

- Weights come from the person's truth (Config.Custody.demeanour): guilty people run and fight more often. Only a person rolled armed can be Hostile.
- Tells: before anyone runs or draws, the run host plays a 1.5–3 s tell every participant sees, and participants within 25 m get a HUD hint such as "Watch his hands" (Config.Npc.tellHints). Nobody draws without one; the weapon is given when the tell ends.
- Feint: a surrendered unarmed suspect may bolt when no participant is within 6 m and none aims at him for 5 s (flee_arrest feint chance, 0 by default), never while worn out with a participant within Config.Flee.giveUpRange. Killing him still fails the mission.
- At a stop the car rolls yield, flee or fight when the lights trigger fires: a yielding car pulls to the kerb with hazards on and engine off; a fleeing car drives recklessly; in a fighting car armed passengers may shoot at participants within 40 m (drive-by chance) and a boxed-in driver may ram the nearest participant vehicle once for 3 s (ram chance).
- Hostile NPCs only target participants, never bystanders.
- The debrief (result screen, Profile & History, dispute reviews) lists each person's demeanour and what they did (walked away, ran, drew, surrendered, faked a surrender, cuffed, escaped, killed), only after the run has ended.
- Armed people rolled at run time count toward the builder's 40-armed budget at their configured maximum, and toward the run's maxArmedAlive through their server-only armedTruth.

NPC combat (Config.NpcCombat; never changes points or cash)

- Weapons: only Config.NpcCombat.weapons (pistol, combat pistol, heavy pistol, pump shotgun). Any other named weapon gets its replace weapon, else the fallback; an automatic weapon (the game's Automatic flag) is never given, even when listed. A custom file that names one loads with a console warning. Switched off: nothing is swapped and Config.Builder.allowed.weapons is the only check (switching reloads the missions).
- Accuracy: tier and Config.NpcDifficulty adds, times accuracyScale (0.7), at most accuracyMax (18), bosses and drive-bys included; single shots (firingPattern) at shootRate 60, at most average combat skill, no charging, less accurate against several officers, bursts from cars. Whichever game owns an NPC applies these.
- Damage: while the run is live each participant's game halves NPC bullet and melee damage (aiDamage, aiMeleeDamage) and drops headshot multipliers (noCriticalHits), again after a respawn; officerDefense (off) lowers all weapon damage taken. Everything resets at run end. The server drops a hit by a mission NPC that would one-shot an officer of its run at or above lethalCancelAbove (0.75) of his health (cancelLethalHeadshots), so officers can still go down. 60 rounds per armed NPC (ammo).

Where people and cars appear (Config.Spawning; enabled = false spawns everything on the file's points at the old moments)

- The spawn director (every hostile_waves fight: Gang Shootout, Hostage Rescue, Drug Lab Raid, Gang Hideout Raid, the Weekly Boss): wave 1 appears once an officer is within activateRange (150 m) of the fight. Every hostile appears at least minDistance (40 m) from every officer (minDistanceIndoor 15 m in a fight marked indoor), never behind an officer, a wave from one side only. A wave short of points spawns the rest later as officers move or hostiles fall; after waveDelayMax (20 s) points down to hardMin (20 m) are allowed, never closer. A point a living hostile or uncollected cuffed suspect stands on is skipped. The boss uses his own spot when allowed.
- Counts are never cut, except: a wave still short leaveOutAfter (45 s) after it began waiting, while nobody of the fight is standing, leaves out what it could not place (warning in Admin → System → Problems); never before one hostile of the fight has appeared; 0 waits for ever. nextWave.afterSeconds counts from the wave's first hostile. A location with no spawn points spawns nobody and the fight completes after its minimum time.
- Staging (fights with stage = true: the raids' objective 2; stageAhead): wave 1 is placed by the same rules while the officers stack up, calm and unarmed (no weapon or fight settings until it wakes; still counted armed for the caps). It wakes when the fight starts, when one of it is hurt, or when an officer comes within stageWakeRange (12 m) of one of it (not an officer nearer a breach entry); woken early it fights, nothing more is staged and the fight waits for the breach. What could not be staged comes when the fight starts.
- Hidden points first (preferHidden, losTimeoutMs 1500): when more points pass than needed, up to 4 nearby officers' games report which they can see (head and camera to 1.0 and 1.7 m above the point); unseen points are used first, and of equal sides the more hidden one wins. No answer in time = all seen, the mission's order.
- The ground probe (ground: collisionTimeoutMs 6000, interiorTimeoutMs 5000): loads collision (and the interior) at a point, finds the highest ground under it (from 2 m, then 50 m over it; under a surface less than 2 m over the point it uses the floor beneath when that is the smaller move) and judges it ok when the height is in its kind's range (person -0.3 to 1.6 m, vehicle -0.2 to 1.5 m, object -0.1 to 0.5 m), else snaps it to the ground when that moves it at most snapWithin (3 m). Otherwise it reports no ground, under the ground, floating, in water, inside not loaded or in a wall (a person's or vehicle's space hitting the map or an entity). Check spawn points (Admin test mode) and the placer use it.
- The placer (place): every new mission person, vehicle and object is made frozen with a placement ask. A participant's game (the owner, or the nearest participant taking it over from a bystander's game) probes the point and moves the entity straight onto the ground there (never another spot), then lets a person or vehicle go (objects and cuffed people stay frozen) and tells the server once; a bad point leaves it frozen. Seated or attached entities go with their parent and count as placed; one already more than 3 m from its point counts as placed and is left. At most four at a time per game.
- The server side (placeTimeoutMs 8000, retries 2, onTimeout 'unfreeze'): a placed answer counts only from a participant of the run, for the current ask, within snapWithin + 2 m in height. A bad answer moves it, the same entity, to another allowed point the block offers (at most retries times, one console warning each), else it is let go where it is. A new non-participant owner within activateRange re-freezes it. The wait counts only while a participant is within activateRange and no participant's game has said it is checking (at most 34 s plus the probe timeouts). On timeout it is let go ('unfreeze') or removed and treated as killed ('delete': a removed hostage or escort truck fails that objective). An entity the server only moved (the warrant suspect at the door, the parked prisoner transport) is always let go.
- Warrant doors and scatters (flee_arrest): Warrant Service's associates appear at the knock (or when a door NPC dies first; associatesAtKnock): each at least minDistanceIndoor from every officer, never behind the door officer (behindAngle off his line from start to door), unseen first, one side, armed and hostile at once. The suspect waits at the door from the start (no suspect point = nobody at the door); one who surrenders is stood on the door step and placed. Every associate and scattering suspect (Prison Break's inmates, the raids' cooks and runners) gets his own point, never within 1.5 m of another person or vehicle of the run; scatters appear once an officer is within activateRange, minDistance from every officer, never behind one. Too few points is reported once and the rest wait for a free point; after waveDelayMax the ring round the points (1.25 m per lap) and a scatter's escape-route starts are offered too. A scatter's suspect flees along the escape route starting nearest him (Config.Flee.nearestRoute; routes within 5 m as near take turns). Suspects still short leaveOutAfter after waiting, once one appeared and the rest are caught, dead or escaped, are left out.
- Field contacts (field_contact): a Suspicious Activity scene, and each parked car of Parking Patrol, appears once an officer is within activateRange while every officer is further than the approach distance plus sceneOutside (25 + 10 m); after waveDelayMax hardMin is enough, after sceneWaitMax (45 s; 0 = wait) it appears anyway with a warning. The HUD and checklist count the cars still to come. The returning driver (citation or impound) and the thief (first inspect of a stolen car) appear contactRing (25–40 m) from the car on a footpath point in front of the acting officer, out of his sight, 20 m from every officer (server-checked; fallback round the car, 25 m from every officer), are placed, then walk up; the driver acts (takes the ticket, argues, drives off) 3 s after reaching the car (4 m) or walking as long as that takes; the thief runs once an officer is within thief.runAt (15 m). The objective never ends while one is on his way.
- Pursuit cars (pursuit): a car made on the road route itself (spawnOffset, a race waypoint, an open route's first point) is lifted vehicleLift (0.5 m); file car points are used as written. Every pursuit car goes through the director in its slot order (its slot, then two further back; no line-of-sight ask), minDistance from officers (hardMin after waveDelayMax), then the placer. A violator following another up the same route (Traffic Enforcement's second) appears secondViolatorUpstream (200 m) up the road from the furthest officer within 100 m of it, and counts as past the officers once past where he stood. A location without a start never places a spawnOffset car from a player's position (warning; other points used).
- Armored Truck Escort (escort): the truck is made on the route's first point, vehicleLift over the road, only while no vehicle and no officer is within 6 m (officers are told once to keep the start clear); after waveDelayMax it takes the first free of four spots 10 m apart further along (warning). Each ambush car is made at the route height plus vehicleLift on its own slot when the director allows (minDistance from every officer and lead car, never behind; hardMin after waveDelayMax). With ambushAheadOnly it is never on a vehicle (4 m), within 40 m ahead of the truck or behind it: its slot slides along the route 15 m at a time up to 300 m, and once the truck is past the slots they start 100–115 m ahead of it. A car with no slot waits; a wave still short when the truck arrives keeps what it has (none = left out, warning).
- Hostage Rescue (protect_rescue, hostagesAt = 'objective'): hostages appear when their objective starts, once an officer is within activateRange, each on its point minDistanceIndoor from every officer and never behind one; after hostagesWaitMax (10 s; 0 = wait) they appear anyway with a warning. No hostage points = no hostage (warning). 'runStart': at run start. The engine warns once per block whose prepare makes entities, unless an owner setting asked for it.
- Manhunt (search_area): nothing appears when the search starts. Each fugitive has his hiding spot (the circle shrinks towards it) and appears there once an officer is within activateRange and every officer is minDistance or more away (no hardMin); after waveDelayMax of waiting he hides on another free spot in the circle (console line). Each clue appears under the same rule, or closer where no officer can see it (preferHidden; hardMin after waveDelayMax). What appeared stays; "Check clue" is offered only on a clue that is there.

Runners tire (Config.Flee)

- The server times every NPC fleeing on foot: sprint sprintSeconds (10), jog jogSeconds (12), walk walkSeconds (8), then spent; each person's times vary by jitter (25%, from the seed) and the NpcDifficulty fleeMult ('hard' +20%, 'easy' -20%). Only time fleeing on foot counts (in a vehicle he sprints and does not tire); the time is kept across stops and runs on. With no participant within recoverRange (60 m) for recoverSeconds (20 s) he recovers. armedTire = false: a person with a visible weapon never tires.
- The gait goes in his cp bag only when it changes. The owning game (any participant's, not only the host's) caps him to a run while jogging and a walk when walking or spent, at jogRate (0.95) or walkRate (0.85), with windedClipset. A tired runner with no route runs 40 m navmesh legs away from the nearest officer (60 or 90 degrees off along an obstacle, never back towards the officers), else GTA's flee task held to his pace; a game that does not run his AI gives him that after 3 s standing still. His own pace returns when he stops fleeing, recovers, sits in a vehicle or Config.Flee is off.
- A spent runner with a participant within giveUpRange (30 m) gives up at once, the owning objective's own way (flee_arrest suspects and inmates, a pursuit's stop-mode runners, search_area fugitives, field_contact runners; never a consensual walk-off or a pursuit's follow mode): exhausted = 'surrender' kneels, 'handsUp' stands with hands up (Cuff suspect offered either way), 'walk' walks on and gives up only by the other rules. A spent armed runner gives up before he can turn to fight; one already fighting is no runner until he runs again. A runner nobody keeps up with still escapes.

## Scoring, points & XP levels

The server works out points from the mission type's points in config, adjusted by performance and team, and caps them at 2× the type points so no single run dominates the board.

\text{Points} = \max\left(0,\ \min\left(2P,\ \left(P + \text{Bonuses} - \text{Penalties}\right) \cdot M_{\text{team}} \cdot M_{\text{cross}} \cdot M_{\text{streak}}\right)\right)

- P: the mission type's points in Config.MissionTypes × the mission's star multiplier (Config.Difficulty.pointsByStars, 1.0 for every star by default). The Weekly Boss uses Config.Events.weeklyBoss.points. Wherever a mission card, setting or comment says "type points", it means P.

- Bonuses and penalties: the mission card's bonuses and penalties are shared by every participant; vehicle damage, pedestrian hits, lights and siren, shooting a surrendered NPC, the first-run bonus, rapid response, every disposition grade (correct_disposition and the decision penalties), unlawful_search, stop_without_cause, unsearched_transport, excessive_force and lab_fire are personal to each officer.

- M_team: the points team multiplier from the tier table (× 1.00 solo up to × 1.25 at Critical), using the run's points and cash tier (see When someone leaves mid-run).

- M_cross: × 1.10 when the participants come from 2 or more departments, otherwise × 1.00.

- M_streak: personal; +5% for each consecutive day with a completed run, up to +25%, reset after a missed day, except that up to Config.Scoring.streakGraceDays missed days a week (1 by default, counted from the weekly reset) are forgiven: the streak carries on, but a forgiven day adds nothing.

- Points are worked out separately for each participant with this formula and rounded down to a whole number, never below 0. Type of the Day doubles the result after the cap; a department's happy hour points bonus (happyHourPoints, fixed at the accept) multiplies it after that, on a Completed result only and never on test runs, Cross-Department runs or the Weekly Boss. A Failed result earns 25% of P × the share of objectives completed; an Abandoned result earns 0.

- Manual awards and goal rewards are stored as their own rows in cp_mission_runs (mission_type = 'manual_award' or 'goal') and count only toward the Overall and Department boards. These rows use state = 'completed', the same word as their end_reason, and the goal id or 'manual_award' as mission_id, and they never count as runs (completed-run counts, goals, streaks, badges, the hourly cap, bounties and the 3-run minimum).

Common bonuses and penalties (apply to every mission unless its card says otherwise; the twist bonuses are Config.Events.twists and the other values live in Config.Scoring.common)

| Bonus or penalty | Value |
|---|---|
| Finished within 75% of the time limit | +20% of P (not EVOC Course or Pursuit Sim, which use medals) |
| No damage to the officer's vehicle (engine and body above 950) | +10, personal |
| First completed run since going on duty | +15, personal |
| Each twist of the run (one line per twist) | +25% of P for Armored Hostiles and Radio Silence, +20% for Time Crunch (each × the leading department's twistPoints Mission control); together at most +70% of P (Config.Events.twistMaxPoints) |
| Heavy damage to the officer's vehicle (body below 500; not in missions with vehiclePenalties = false) | −25, personal |
| NPC pedestrian hit by the officer's vehicle | −30 each, personal |
| Lights and siren used during a mission with quietPatrol (Beat Patrol, Business Check, Illegal Parking Patrol), after the first participant arrives at the start | −10, personal |
| Shooting a surrendered NPC | −20 each, personal |
| Killing a surrendered or unarmed suspect, fugitive, inmate or hostage | Mission failed for everyone |
| Reached the start of a claimed mission call within its response target (server-posted calls only; never a paged or staff-created call) | +10% of P, personal (Config.MissionCalls.rapidResponse) |
| Melee or taser hit on a detained, escorted, seated or compliant person (detected best-effort, see Police actions & decisions) | −10, personal (excessive_force) |
| Lighting a car up before its violation was observed (Traffic Enforcement) | −15, personal to the officer whose lights started the stop (stop_without_cause) |
| Releasing a person after their warrant or weapon was revealed to the decider, or a car after its plate came back stolen, after the case-fail confirm | Mission failed for everyone |

Vehicle damage where contact is expected: a mission can set vehiclePenalties = false to turn off the heavy-damage penalty, because contact or gunfire damage is part of the job there. The no-damage bonus can still be earned, and a card's own ramming penalties still apply. Built-in missions with it off: Street Race Bust and Stolen Vehicle Takedown (boxing in and PIT stops), Armored Truck Escort (ramming ambush cars), and Warrant Service, Gang Shootout, Hostage Rescue, Prison Break and Weekly Boss: Kingpin (vehicles take gunfire).

XP & XP levels: XP equals lifetime points and never resets. A run's points are added to XP when they count (a flagged run's only once it is approved) and taken away if the run is voided. Levels, the XP level bands, daily limits and the service record are in XP levels & service record.

Achievement badges: Iron Wheels (20 completed runs with no vehicle damage), Sharpshooter (10 Gang Shootouts with no participant downed), Road Warrior (100 Patrol missions), Partner in Crime (50 unit runs), Joint Task Force (10 runs with 2 or more departments), By the Book (100 Best dispositions) and First Responder (25 mission calls with rapid response). The counts are in Config.Recognition.badges (keyed by badge id, e.g. iron_wheels; 0 = off).

Daily and weekly goals: each officer gets one daily goal (picked at the daily reset, Config.Time.resetHour) and one weekly goal (picked on Monday) from Config.Objectives.dailyGoal / weeklyGoal, e.g. "Complete 2 Patrol missions" or "Complete 1 cross-department run". Progress is counted from the officer's runs since the goal was picked. Goals are picked with a random seed made from the date (or the week's start) and the officer's citizenid, so a restart keeps the same goals and nothing needs storing. Finishing one adds +50 (daily) or +200 (weekly) points once, as a 'goal' row. Goals may also count mission calls or a stat (arrests, citations, impounds, rescues, vehicles stopped, evidence, correct decisions) from completed rows only (the kinds in Config.Objectives). A department's supervisor may narrow the lists his department's officers draw from to some of the admin's goals (the goals Mission control, shipped off): the pick counts from the next weekly reset, the points stay Config.Objectives.dailyGoal.points / weeklyGoal.points, and the setter keeps the whole lists.

## XP levels & service record

Points, XP and levels are three views of one number.

| Name | What it is | Where it shows |
|---|---|---|
| Points | What one run earned; ranks the Weekly, Monthly and Season boards | Result screen, boards, history |
| XP | Every point an officer has ever earned (counted runs, goal rows, manual awards); never resets | The XP bar |
| XP level | A number worked out from XP (Lv 1–50, then prestige stars); its band gives the XP level name | The number in the header, boards and unit lists; number and name on Home and the profile |

- The result screen shows "+142 points" once, and under the level bar "+142 XP · 312 XP to Lv 24". Points go to the boards of their period; XP stays for good.

- Level curve (Config.Recognition.levelCurve): level 1 starts at 0 XP; reaching level n needs round(100 × (1.07^(n−1) − 1) ÷ 0.07) XP, so each level needs 7% more than the one before. Level 10 ≈ 1,200 XP, 25 ≈ 5,800, 38 ≈ 16,000, 50 ≈ 37,900. After level 50, every 10,000 XP adds a prestige star (Lv 50 ★2).

- One ladder: the XP level names and badge colours still come from Config.Recognition.levels, and each name is now a band of numbered levels (Config.Recognition.levels[n].level: Probationary Lv 1–9, Patrol Officer Lv 10–24, Senior Patrol Lv 25–37, Veteran Lv 38–49, Elite Lv 50 and prestige). The xp thresholds in the file stay close to each band's first level. The header shows only "Lv 23" next to the Qbox rank; Home and the profile show "Lv 23 · Senior Patrol".

- Levels are cosmetic. They never change the Qbox rank, never unlock missions or mission types and never change pay. They unlock looks only: avatar presets, personal accents and the avatar frame colour (each entry in Config.Profile and theme.personalAccents may set a level), plus an optional level-up item (Item rewards), which is the one admin-configured exception to "cosmetic" and is off unless the owner fills Config.Rewards.levels.

- A level-up shows one toast (scoring.level_up: "Lv 24", or "Lv 25 · Senior Patrol" when a band starts) and a banner on the result screen; there is no second level-up event. XP from a flagged run is added only when a supervisor approves it (the result screen says "XP pending review") and is taken back when a run is voided.

Daily limits

- Config.Limits.maxCompletionsDay (0 = off, the default) caps an officer's completed runs per day (from the daily reset), and a mission type may set its own dailyLimit in Config.MissionTypes. Cross-Department Missions and test runs never count and are never blocked.

- A locked card on the Mission Board and on Dispatch shows "Daily limit reached (resets 00:00)", naming the member who reached it in a unit. Home shows "Missions today 3/10" while a cap is on.

Service record (Profile & History, public profiles, Supervisor UI → Department Report, Admin UI → Officers)

| Stat | Counted from |
|---|---|
| Runs completed, success rate | Completed and failed rows (abandoned rows are not failures) |
| Arrests | One per person, credited once to the officer who first cuffed them or decided Arrest: a validated cuff of a person the mission marks as a suspect (flee_arrest, pursuit and hostile targets), or an Arrest disposition graded Best or Acceptable. A wrongful arrest never counts, nor a Detain followed by Release |
| Citations, impounds | Cite and Impound dispositions (Best or Acceptable) |
| Vehicles stopped | Suspect cars stopped in pursuits the officer was part of |
| Rescues | Hostages brought to the safe marker |
| Evidence | Lawful finds (vehicle and person searches, property searches, seized stashes and caches) |
| Correct decisions | Best dispositions as a share of all dispositions (Judgement), with the counts of Best and of Best or Acceptable |
| Mission calls | Calls answered, average response time, rapid responses |
| Medals | Gold, Silver and Bronze on EVOC Course and Pursuit Sim |
| Commendations | Count, newest first on the card |
| Personal bests | Fastest completion of each mission the officer has already completed; never a mission they haven't played |
| Favourite partner | The officer they shared the most completed runs with |

- Every stat except runs and success rate comes only from rows with state = 'completed' that are counted (not voided, not flagged), plus the archive, so it can't be edited, follows voids, and can't be farmed by doing the easy part of a run and abandoning it. Failed and abandoned rows add nothing to arrests, citations, impounds, rescues, evidence, decisions, goals, bounties or badges.

- Kills are never shown on any screen, board or webhook. Only the officer's own profile shows a clean-arrest rate (arrests ÷ (arrests + suspects killed by them)).

## Cash payouts

Every participant in a Completed run is paid cash: the mission's base payout multiplied by how difficult the run was.

\text{Cash per participant} = \operatorname{round}\left(B \cdot M_{\text{tier}} \cdot M_{\text{mod}}\right)

- B: the base payout. If an admin has set a payout for the mission, B is that amount. Otherwise B is the mission type's payout × the mission's star multiplier (Config.Difficulty.cashByStars, 1.0 for every star by default). The Weekly Boss uses Config.Events.weeklyBoss.payout unless an admin has set one.

- M_tier: the cash multiplier from the tier table (× 1.00 at Standard up to × 1.75 at Critical).

- M_mod: the run's twists: each twist's cash multiplier (× 1.25 Armored Hostiles and Radio Silence, × 1.20 Time Crunch), multiplied together and capped at × 1.95 (Config.Events.twistMaxCash); × 1.00 without a twist. A department's twistCash Mission control may raise each twist's multiplier inside the admin's bounds (read at the accept); the cap still applies.

- M_bonus: a department's happyHourCash Mission control, for a run it leads that was accepted while a happy hour ran (fixed at the accept, so the end of the hour never cuts it); × 1.00 otherwise, and always × 1.00 on test runs, Cross-Department runs and the Weekly Boss. Cash per participant is then round(B · M_tier · M_mod · M_bonus), and Config.Cash.dailyCap still cuts the payment.

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

- Admin payouts are permanent until an admin changes or clears them (restarts, season resets, re-publishes and reloads keep them); an admin-set type is locked for supervisors ("Set by admin").

- Supervisor limits: a supervisor can set a type's payout only between 50% and 200% of its config default (Config.Payouts.supervisorRange), at most once every 30 minutes per type (Config.Payouts.supervisorCooldown), and must give a reason. Admins are bound only by the overall range.

- A mission with an admin payout ignores later changes to its type's payout.

- Clearing (admin only) deletes the stored value: a mission goes back to its type's payout, and a type goes back to its config payout and is unlocked for supervisors.

- Overall base payout range: $0–$25,000 (Config.Cash.minPayout and maxPayout). There is one set of payouts for every department.

- The Mission Board shows the cash per officer as a range for the unit's size, for example "$1,040–$1,300" for a unit of 4 on Tactical with random twists on (Config.Events.modifierChance above 0; the top covers the best one), covering any admin payouts in the pool. The twists the officers choose show their own bonus on the accept step.

- Every change is written to the audit log (old value, new value, who, reason) and posted to the audit webhook.

How cash is paid (by the server, once per participant per run)

- Claim the row first: UPDATE cp_mission_runs SET cash_status = 'paying' WHERE id = ? AND cash_status IN ('none','held','pending'); no row changed = stop. paid, capped, unfunded and forfeited are final (only the Full admin control money tools, all shipped off, act on them).
- Work out the amount; pay only up to Config.Cash.dailyCap for the day (0 = no cap).
- Society source: removeAccountMoney from the department's account; false = pay $0, final status unfunded, the officer and online supervisors told.
- player.Functions.AddMoney(Config.Cash.account ('bank'), amount, 'crimson-police-mission'); for bank payments handleTransaction(citizenid, 'Crimson-Police', amount, 'Mission payout: <mission label>', '<department label>', '<character name>', 'deposit', 'CP-<run_uuid>-<citizenid>'), plus a 'withdraw' on the society account.
- Write cash_paid and the final status (capped if the cap cut it, else paid). A row left in paying after a crash is never retried automatically: Admin UI → Payments (and Leaderboards) lists it for a check against the bank history, and the admin marks it paid (no money moves) or, only with the Pay again tool on, pays it again as CP-<run_uuid>-<citizenid>-r2 (step markers make sure a department is never charged twice).

A flagged run's cash is held until a supervisor approves it. If the officer is offline at that moment, the payment waits (cash_status = 'pending') and is made the next time they load in. A voided run's held cash stays held until its 48-hour dispute window closes or a dispute about it is rejected, and is then forfeited (cash_status = 'forfeited'). Voiding an already-paid run does not take the money back (only the Take back money tool of Full admin control does, and it ships off).

## Leaderboards

Four time-boxed boards rank officers by points earned in each period. Cash is never shown on public boards.

| Board | Window | Resets | Recognition (suggested) |
|---|---|---|---|
| Weekly | Monday to Sunday, starting at the reset hour (Config.Time.resetHour, 00:00 server time by default) | Every Monday | Top 3 posted to Discord and announced on the Home screen; "Officer of the Week" badge |
| Monthly | Calendar month | 1st of the month | Top 3 announced on the Home screen |
| Season | From the season's start to its end (an admin starts and ends it; 8 weeks suggested) | When an admin starts the next season | Season title and badge for the top 10 |
| All-time | Lifetime XP (Overall filter only) | Never | Display only |

Filters: Overall · Patrol · Training · Investigation · Tactical · Unit (points from runs with 2+ participants) · Cross-Department (points from runs with 2+ departments) · Department (one board per entry in Config.Departments).

Rank by: Points (default) · Missions · Arrests · Impounds · Citations · Rescues · Mission calls · Judgement. The All-time tab keeps ranking by XP and shows each officer's level. Live catches (suspects detained in live cases, Config.RealPlayers.liveCrime) is one more tab the owner can add to Config.Leaderboard.metrics (not on the shipped list).

- Missions counts completed runs; Mission calls counts completed runs claimed from a call; Arrests, Impounds, Citations and Rescues sum those columns over completed rows only (`WHERE state = 'completed'` plus the void and flag rules); Judgement ranks Best dispositions (decisions_best) as a share of all dispositions (decisions_ok + decisions_bad), and needs at least 10 decisions in the window (Config.Leaderboard.minDecisions), with more decisions winning a tie.

- Every metric uses the same period, filter, 3-run minimum, privacy toggle, void and flag rules, pinned own row and 60-second cache as points. Ties go to more points, then fewer failed runs, then whoever reached the score first.

- Every row shows the officer's level badge and avatar. Cash and kills are never shown.

- Optional weekly badges per metric (Config.Recognition.weeklyBadges, e.g. { 'arrests' } gives "Top Arrests of the Week"); Officer of the Week stays by points.

Ranking rules

- Rank by points (or the chosen metric); ties go to fewer failed runs, then to whoever reached the score first.

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
| Weekly bounty | Each Monday the server picks one objective at random from Config.Objectives.bounty.objectives (e.g. "Most Tactical missions", "Most cross-department runs", "Most arrests", "Most mission calls"), and an admin can override it for that week. The department with the highest count per active officer wins a bonus of 10% of the challenge points its officers earned that week, added once when the week closes |
| Transfers | Points stay with the department the officer was in when the run ended |
| Tie-break | More completed runs, then more unit runs |
| Winner | "Season X Champions" banner on members' Home screen, a trophy badge for members with 3+ runs, and a Discord post |

Tablet: the Department Challenge screen shows each department's score bar in its own theme colour, weeks left, this week's bounty and the viewer's department's top 5 contributors.

## Officer profile

Profile & History has an Edit profile dialog and the Service record, Commendations and Look cards. Public profiles show the same minus cash, and minus name and picture when the officer hides his name.

| Part | Rules |
|---|---|
| Picture | Initials (default), a preset from Config.Profile.avatarPresets (some unlock at a level), or an image link while Config.Profile.avatarUrls.enabled: https, an allowed host by exact match (avatarUrls.hosts: r2.fivemanage.com, i.imgur.com), at most 255 characters, a path ending .png/.jpg/.jpeg/.webp (a query string is ignored), no spaces, quotes or angle brackets. cdn.discordapp.com is not a default (signed links expire within a day); Config health notes Imgur is blocked in some regions. With requireApproval (default) a new link is Pending, and others keep the old picture until a supervisor of the department or an admin approves it in Review Queue → Profiles. 3 link submissions a day. A picture that fails shows the initials |
| Bio | Up to 280 characters and 3 lines, plain text (links not clickable), trimmed, control characters removed; words in Config.Profile.bannedWords and config/banned_words.txt are refused. With bioRequiresApproval (off) a new bio is Pending. Labelled "Visible to other officers". One profile change every 5 minutes |
| Callsign | Read live from Qbox (SC-Police's /callsign), never edited here; missing = "Set it with /callsign" |
| Look | Appearance, personal accent and tablet size (85–125%), own tablet only. English only, so no language choice |
| Service record | See XP levels & service record |

Commendations (Config.Recognition.commendations)

- Supervisors (Department Report → activity) and admins (Admin UI → Officers) Commend: a kind (Valor, Lifesaving, Teamwork, Professionalism, Leadership, Investigation), a citation of 10–255 characters, optionally the run. A supervisor: own department only (crossDepartment = false), never himself or for a run he was on, 3 a day, not the same officer and kind within 7 days; admins anyone.
- No points or cash, never counted toward goals, badges, bounties or boards. The recipient gets a toast and a Home announcement for 7 days; with announce the board webhook posts it. The issuer or an admin revokes with a reason; all audited. Config.Profile.showMdtCommendations (off) shows SC-Dispatch MDT commendations read-only, tagged "MDT".

Field training (Config.Recognition.fieldTraining, off)

- A supervisor (Department Report → Field training → Pair trainer) or admin pairs a rookie with an online trainer of the same department at Qbox grade trainerGrades.<department> or more (else supervisorGrade); never his own character as the rookie; one trainer per rookie, at most rookiesPerTrainer per trainer, who is not in training himself. End training (two clicks) unpairs.
- A completed, unflagged run counts for the rookie when his trainer finished the same run: one towards the task of its type (tasks, a count per type), up to the count; test runs never. At the count the trainer is told and signs it off (Profile → Field training, optional note up to 255 characters), once per task, only his own rookie's. All signed off = done, with the badge Config.Recognition.fieldTraining.badge (also in the admin Grant / Revoke list while on).
- requireTrainerFor (empty): a rookie in training may accept or claim a listed type only with his trainer in the unit (err.fto_trainer_needed / err.member_fto_trainer_needed), and joins a live case of a listed type as backup only when his trainer is on it; his Profile card lists those types.
- trainerBonus (0, at most 1000): points per sign-off as a manual award row (mission id fto_bonus, "Field training sign-off", rookie and task as reason).
- Audited (ftoPair, ftoUnpair, ftoSignOff); kept in cp_officers.field_training (both storage modes). Department Report shows every rookie's progress per task.

Moderation and reports

- Review Queue → Profiles (supervisors, own department) and Admin UI → Officers: approve or reject a pending picture or bio, clear a bio or picture (reasons required), handle reports; all audited.
- Report profile: any officer, a reason (picture, bio, other) and up to 140 characters; goes to the reported officer's department's Review Queue and to admins; 3 per reporter a day, one per profile a day (Config.Profile.reports); audited; the reported officer is never told who. A report of an approved picture shows the reviewer the live image.

Officer options (Config.OfficerOptions)

My options (Officer UI, after Profile & History; hidden while enabled is false) holds each officer's choices for his own tablet. Each row says where it is kept: This character (cp_officers.options, any PC) or This PC (every character on it). Each group's card saves on its own and has Back to default. Its Tablet look and privacy card edits look, size, call alerts and hide my name with Edit profile's rules. My keys lists the four Crimson-Police keys and their binding (changed in GTA Settings > Key Bindings > FiveM). Every option is allowed by default except Auto-Ready; option values are in the config copy.

- Mission HUD (this PC, applies at once): side right or left; HUD size inside bounds.hudScale; Compact HUD (current objective, done count, timer); Fewer animations (no slide-ins, no flashing off-route warning).
- Easier to read (character): Use my tablet look on the HUD (HUD, result card and notifications take the officer's appearance and accent; the Admin UI keeps its theme); Text size Large (15% bigger on tablet and HUD).
- Pop-ups (this PC): notification time Short (3 s / 5 s for warnings), Normal (5 / 7) or Long (8 / 12), a notification with its own time keeps it; result card time inside bounds.resultTime; Fewer pop-ups during a mission (invites, commendations, rewards and profile news that are not warnings go to the bell; route, custody and mission messages, warnings and errors always pop up); Key hints (name the ready, Dispatch and contact keys; never an unbound, mouse or pad key).
- Mission Board (character): Favourite types first; Hidden types fold under "Hidden types (n) - Show" (still openable; a favourite never folds; one type always stays); Accept in one click (no confirm, its lines as a footnote, Twists button for the old dialog, the Weekly Boss still asks); My usual twists pre-ticked on accept and claim where offered (they replace the department's ticks; an unoffered twist is never ticked or sent; a removed twist is dropped; the server checks at accept). Only order and folding change: every check and the random draw still run.
- Dispatch (character): Claim in one click (no confirm; the claim window still ranks); Call pop-ups 'favourites' (only favourite types pop up, every call still listed; no favourites = all; cached with calls_muted for 30 s); Tablet key opens Dispatch for 20 s after a call pops up (claims nothing).
- Opening the tablet: Open on (character) 'last', 'home' or 'active_on_run' (Unit while a ready check waits, Active Mission on a run); a screen Lua names, the Dispatch key or the after-call key wins. Remember my filters (this PC): Dispatch's filter and the Leaderboard's choices.
- During a mission: Abandon asks in a dialog (character; off = "Click again to abandon" for 3 s, always two presses; cooldowns unchanged); Recalculate in one click (character; maxRecalcs still counts); Distances (this PC) metric or imperial (ft under 0.1 mi, then miles) on HUD, run bar, Active Mission, Contact panel and Dispatch (the Builder stays metric).
- Map: Objective GPS (character) 'route', 'waypoint' (a waypoint on each new objective pointer, never over his own, removed with the objective) or 'off' (the button still works); Objective line on the HUD (this PC); Colour-blind map colours (this PC: blue, yellow, orange, white, purple, never red or green). They only hide or recolour: Radio Silence still hides, and the drive to the start keeps its route.
- Unit: Auto-Ready (character; locked off by allow.autoReady = false): answers Ready when the leader accepts, only while the officer is at the keys (no pause menu, input in the last 60 s); the server counts it only while allowed, on, and within autoReadyRange (150 m) of the leader; never for a Cross-Department join; a manual Not ready still wins.
- Sounds (this PC): mission call tone, unit tone, objective cues; on or off only; pop-ups still show; the Builder's sounds unaffected.
- Rules: allow (false = locked to the default), defaults and bounds; a department's own in Config.Departments.<key>.officerOptions win for its officers. An option is a switch, one choice, several choices or a number; a choice no longer offered is dropped and a number out of bounds clamped; only values differing from the default are saved. A disallowed option is ignored, never deleted. Only an on-duty officer changes his own, server-checked; Settings refuses an officerOptions naming an unknown option or impossible value.

## Item rewards (optional)

Off by default (Config.Rewards.enabled = false). When on, completed runs can also give ox_inventory items. Only admins set them, in config; mission files and the Mission Builder never have a reward field, just as they have no payout field.

- Sources: a roll per mission type or per mission (chance, number of rolls, a weighted pool of items and counts), a higher chance at higher tiers, EVOC and Pursuit Sim medals, lawful evidence finds (each raises the run's chance by 10 percentage points, up to 30), daily and weekly goals, level-ups, the Weekly Boss, and season champion and top 10.

- Who: each participant of a Completed, non-test run who met the presence share. A flagged run's rewards are held until a supervisor approves it; a voided run's are forfeited when its dispute window closes, like held cash.

- Rolls come from the run and the officer (a seed of run id and citizenid), so reconnecting or reopening the tablet can never reroll them.

- Limits per officer per day: Config.Rewards.dailyItemCap items and dailyValueCap of item value (each item's value is set in config); rolls past a cap give nothing.

- Never: weapons, ammunition, armour, bandages, money items, or anything on the forbidden list; never to a player in Crimson-Arena; never dropped in the world. Forbidden patterns and the Crimson-Arena names match case-insensitively through the loader's existing item-name validator, so WEAPON_PISTOL and weapon_pistol are both refused. Rewards are tagged cpReward = <id> and never cpItem, so the mission-item sweep leaves them alone.

- Delivery: the server checks CanCarryItem, then gives the item. If the officer is offline, in Crimson-Arena or has no room, the reward waits in the Rewards locker on Home (Claim, checked again by the server) and is retried when they load in and 10 seconds after they leave the arena. A reward stuck while being given is listed for admins.

- At start the server checks that every configured item exists in ox_inventory; a missing one is turned off with a console warning and shown in Config health.

- Out of the box: Config.Rewards ships an example pool per mission type (examplePools) made only of standard ox_inventory items (water, burger and sprunk, plain consumables from ox_inventory's default item list; Config health warns if one is missing), with values, commented "example: safe values". It is used only when the owner turns item rewards on (enabled = true) and sets useExamplePools = true. Config health shows "Item rewards: off (example pool available)" so an owner comparing products sees the feature at once.

- The result screen, the history breakdown and Admin UI → Leaderboards → Item rewards show what was given, held or forfeited.

## Mission Builder

Supervisors build missions on the tablet (Supervisor UI → Mission Builder) and admins in Admin UI → Missions → Builder: every setting, spots placed in the world, routes recorded by driving, test, publish. No Lua editing or restart; each published mission is also saved as a Lua file. Which builder actions supervisors may use is Config.Permissions' supervisor list (by default build, test, publish and archive their own missions); admins can do everything, including rollback and breaking edit locks.

Flow

- New mission → up to 6 objective blocks, in the order officers do them.
- Details → name, description, mission type (required; sets points and base payout), difficulty (1–3 stars), min and max officers (1–4), time limit (2–20 min), start timeout (5–15 min), cooldown (5–60 min), "Available to" (none = every department), vehicle-damage penalties (off suggested with a pursuit or escort block or armed NPCs), optional items, and bonuses and penalties from Config.Bonuses (a flat one capped at 50 points, a percentage at 25% of P; block settings keep their own ranges). There is no payout field.
- Items: admins only while Config.Builder.supervisorItems is false (shipped): a supervisor's save, validate, test and publish refuse any item (builder.error.item_forbidden) and the field is locked with the reason. Armour, bandages, ammo-*, weapon_*, money, black_money and cash are never mission items. A run hands out a custom mission's items only when its version was published by an admin or the console or edited in code; otherwise none, said once in System → Problems ("items skipped: saved by a supervisor"). An officer can use or sell a mission item before the run takes it back.
- Block settings → each block's panel shows every value with its minimum, maximum and default and refuses anything outside; the ranges and defaults are config/blocks.lua (its copy is under Config). A panel shows the objective name and the basics (hostile_waves: Waves, Enemies per wave, Weapons, Difficulty Easy/Normal/Hard, which set accuracy, armour and health inside their ranges) and folds the rest, with the minimum time ("Flag runs finished faster than") and presence range ("Officers must stay within", 50–800 m), under "More settings"; Details folds all but name, type, difficulty and team size. An error opens the fold.
- Place it in the world → the tablet closes into the placement tool and reopens when done.
- Record routes → escort and pursuit record a road route by driving; a checkpoint route recorded this way is saved as checkpoints.
- Scaling → tick which counts scale with the tier; each block suggests a default.
- Test run → played privately at any tier in admin test mode; points and cash shown, never saved or paid. Optional: an untested draft publishes after "Publish without testing?"; only while Config.Builder.requireTestToPublish is true does a supervisor's draft need a passed test at the tier its maxOfficers reaches (e.g. Heavy for 4 officers); an admin never does.
- Publish → the mission joins its type's pool for the chosen departments and its Lua file is written.

Block settings (every range and default is config/blocks.lua; these are the rules that are more than a range)

- hostile_waves: the next wave comes when this many or fewer are alive, or after its time; spawn points at least 1.5 × the largest wave; behaviour (Hold cover, Balanced, Push) fixed or rolled per run with weights; 0–4 named spawn sets per location, 1–3 used per run; an optional boss; NPC traffic blocked within a radius.
- escort: the truck always keeps to its lanes; ambush points placed on the route at least 150 m apart; stop points added with E while recording, and the wait there never counts toward "Fail if stopped for".
- pursuit: Follow (stay close) or Stop (stop, then arrest); free flee or a recorded route (a race loop); yield / flee / fight percentages when lit up; after the stop Arrest or Contact (the next field_contact objective); observe first (Pace a speeder or Follow a reckless driver) against a posted speed, the overspeed rolled between two values, the pace graded on the median of per-second samples within the pace tolerance; drive-by and ram chances; spawn offset ahead (+) of or upstream (−) of the nearest participant or the observation point (upstream cars drive past the officer).
- checkpoint_route: all in order or a random N; vehicle required = counts only while the officer drives a vehicle (server-checked); optional Gold/Silver/Bronze times; a contact penalty in seconds per hit.
- interact_points: optional logged result (2–4 choices, the correct one rolled by the server); together = 2–4 different officers within a window, the count min(setting, participants left), with solo progress per point when one is left; hidden items are Devices (for a skill_check) or Items to seize; an evidence chance per point.
- skill_check: when the misses run out, fail the case or a setback (a recovery step, a personal penalty for the officer who missed, then a retry).
- protect_rescue: restrained or not, time to free, a safe marker, a penalty per hit, fail if one dies.
- flee_arrest: gives up when aimed at within the aim distance, stunned or a participant stays within 3 m for 3 s (as ticked), and always when worn out by Config.Flee within its giveUpRange; demeanour rolled from Config.Custody.demeanour or fixed; after an arrest cuff only or hand over.
- search_area: the starting circle is also every location's start radius; the circle shrinks to the listed radii after each clue; fugitives run when a participant is within the set range.
- field_contact: Parked cars (5+ kerb spots, each with a posted rule), Scene (a car spot, 3+ person spots, 2+ escape paths) or Stop (the car and people of the pursuit before it); truths from Config.Custody.profileSets; optional transport point.
- process_scene: keeps the latest bodies; the coroner van can be off.

Route recording

- Started from the block's settings: the tablet closes and the recording HUD appears; drive the route in any vehicle at any speed. Every 25 m the position snaps to the nearest road node (GetClosestVehicleNodeWithHeading); samples more than 8 m from a road are rejected ("Off road").
- Saved as road waypoints only: one at every junction or turn over 30° and at least every 150 m, duplicates removed; never the builder's speed, lane or line. At run time the NPC vehicle drives waypoint to waypoint with lane-following driving (TaskVehicleDriveToCoordLongrange) at the block's speed and style.
- Keys: E adds a stop point (escort), Backspace undoes the last 100 m, P pauses, X finishes. Afterwards the map shows the route and its length; Test drive sends the vehicle along it and marks any waypoint not reached within 30 s for re-recording.
- Checks: 0.8–8 km; start and end 300 m apart (a race loop ends within 50 m of its start); a road path between each pair of waypoints (CalculateTravelDistanceBetweenPoints); no waypoint in a no-build zone.
- A patrol (checkpoint route) recorded by driving is saved as plain checkpoints about Config.Builder.route.patrolSpacing (300 m) apart plus its end (at most the block's maximum), so the route checks do not apply. **Place checkpoints** is its main button.
- Stored in the objective as route = { points = { vec3(...), ... }, stops = { { at = <waypoint index>, wait = <seconds> } } } with the block's own speed (km/h) and style, the same format for escort, pursuit and checkpoint_route.

Placement and the point list

- Placement tool: a ghost preview follows the aim; scroll rotates, E places, Backspace undoes, Delete (or Backspace) aimed at a placed point removes it, X cancels and keeps the points as they were, Enter returns to the tablet. Areas are ox_lib zones. A spot failing a guardrail shows red and cannot be placed.
- Point list (Locations step): one row per stored point (the start, then each point of each key; not flee paths or road routes) with number, kind, distance from the start and street, and GPS, Set here (moves it to where the builder stands, spacing-checked) and Delete (autosaved). The hovered row is ringed on the map.
- Teleport (owner decision): the start row and each point row have Teleport while Config.Builder.teleport is on and the builder may (admins always; others with a grant for department and grade in Config.Permissions.builderTeleport, shipped empty). The screen names the point, never a position; the server checks the grant, refuses in the arena, on a run or while down, reads the saved point, audits builderTeleport and sends the coordinates; the client fades, freezes, loads collision, finds the ground, places him and unfreezes. Unsaved changes are saved first. Other tools only set GPS waypoints.
- Show on map: closes the tablet and opens the pause map with temporary blips on the location's start, spawn points and checkpoints (All locations: every start). Client action builderShowMap { points = { kind, coords } } (1–300), refused in the arena; cleared when the tablet opens, on a new show, on unload, entering the arena and resource stop. Read-only, so no config option.

Guardrails (while placing, and again by the server on publish)

- A custom mission pays its type's payout (× its star multiplier) until an admin sets a mission payout.
- Only models, weapons, vehicles and animations in Config.Builder.allowed.
- At most 40 armed NPCs per mission before scaling, over every block (hostile waves, escort attackers, every flee_arrest suspect with an armed chance above 0), with the running total shown; at run time 25 armed alive and 80 entities at once still apply.
- Spawn points on the ground (not in water, walls or the air), at least 30 m from the start, outside Config.Builder.noBuildZones (police stations, hospitals, the prison interior, the Crimson-Arena Trailer Park and lobby by default).
- Armed spawn points (hostile_waves spawns, spawn sets and boss spot, escort ambushPoints, pursuit spawn / spawns, flee_arrest associates) must also be outside the start circle plus Config.Builder.spawnMargin (40 m), measured flat (a 60 m start: 100 m). Hostages, door suspects, scatters, fugitives and field-contact people keep the 30 m, as does a mission with a search_area objective. The placement tool refuses a closer point, publishing refuses it (one message per location and key), and the map and in-world ring show the distance. Points a built-in plays at its own start stay allowed in a duplicate of it (compared with the shipped files at server start, before the built-ins load); moved or new points follow the rule. An older custom file still loads with one warning per location and key; republishing it needs the points moved. The block guardrail at file load stays at 30 m.
- Locations of one mission at least 100 m apart; a custom mission needs Config.Builder.minLocations (1) and an edited built-in Config.Builder.minLocationsOverride (3).
- Start radius 20–150 m, except with a search_area objective: there every location's start radius is its first search_area's starting circle (200–1,000 m, 600 m) and the run starts on entering it.
- Every objective has a minimum time (minSeconds, or the block's default), the time limit is 2–20 minutes, and every block's required points are placed.

Editing safety and lifecycle

- One editor at a time: opening locks a mission for 30 minutes, renewed while editing; an admin can break it. Drafts autosave every 30 s. Editing a published mission works on a draft (the next version) while the published one stays live. Admins roll a custom mission back to its previous version from Admin UI → Missions (from its .bak file).
- Draft → Tested → Published → Archived. Each run records its version. Built-ins are read-only in the builder and can be duplicated. Every save, test, publish, archive and rollback is audited.

Lua export

- Every publish writes missions/custom/<mission_id>.lua with SaveResourceFile, in the shape of a built-in file (see Example files): chances as fractions (30% = 0.30), progress times in ms, a header comment with id, version, type, publisher and time. The previous file is kept as <mission_id>.v<version>.lua.bak; archiving moves it to missions/custom/archived/.
- The file is the source of truth for a published custom mission, loaded on start and reload; a missing one is rewritten from storage with a warning. A developer may edit it and run /CrimsonPoliceAdmin reload: it is checked against the same guardrails and saved as a new version marked "edited in code". If both the draft and the file changed since the last publish, the reload keeps the file, saves the draft as <mission_id>.draft.lua.bak and audits the conflict.
- Mission files (built-in, custom, edited built-in, backup, pasted import) are data, never run (FXServer's Lua has no debug.sethook to stop running text): comments, then one RegisterMission({ ... }) of plain values (strings, numbers, true, false, nil, tables, vec3/vector3 of 3 numbers, vec4/vector4 of 4). Anything else (a variable, a sum such as 10 * 60, joined text, a function, a loop, a key given twice, CfxLua syntax) is refused, naming the file and line in the console and the Admin UI; the last published version stays live.
- Payouts never come from the file: a hand-added payout field is ignored with a console warning.

## Data model

All storage is in cp_ tables. The exact columns are the migration files in Crimson-Police/sql/migrations/ (001_initial.sql is the fresh schema; 002–017 only add) and the column meanings are in docs/dev/ARCHITECTURE.md §3–§5. Leaderboards are computed from cp_mission_runs, one row per participant per run, so every point and payment traces back to the run that earned it.

| Table | What a row is |
|---|---|
| cp_schema_migrations | One applied migration file (number, name, time); created by the runner before 001 |
| cp_officers | One character (citizenid): department, XP, streak and its weekly grace, hide_name, suspension; copies of callsign and rank_label (refreshed from Qbox on load and tablet open, never written back); the profile (bio, avatar and its review state, look, call mute; 004); license, board exclusion, retirement, anti-farm override (008); options (010, JSON of the My options that differ from the default, NULL = all defaults); mission_ban (012, NULL or past its end = none); field_training (015, NULL = not in field training) |
| cp_mission_runs | One participant of one run: run_uuid (shared by the run), operation_id, type, mission and version, location, department, season, participants and departments, tier, first twist (every twist in breakdown), state (completed, failed, abandoned), end_reason, base/bonus/penalty/final points, cash base, multiplier, paid and cash_status, duration, breakdown JSON, flagged with flag_reason, voided; the service-record counts, medal, mission call and response time (003); a void's kind and batch and the cash taken back (008); live_catches (014). mission_type is also 'manual_award' or 'goal' |
| cp_mission_runs_archive | The same columns in the same order (the retention job copies with INSERT ... SELECT *) |
| cp_seasons, cp_badges | Seasons (name, start, end, active) and earned badges (citizenid, badge, time) |
| cp_operations | One Cross-Department Mission (mission, launcher, status, times; the last launch times Config.CrossDept.cooldown) |
| cp_custom_missions | One custom mission: type, published version and definition, draft version and definition (autosaved), draft_tested, file_path, edit lock |
| cp_dept_bounties | A department bounty (objective, winner) |
| cp_type_payouts, cp_mission_payouts | Base payout per type (admin_locked = an admin's permanent value; updated_at also times the supervisor cooldown) and an admin's payout per mission (permanent until cleared) |
| cp_disputes | One dispute per run row; goes_to supervisor (flagged or voided) or admin (failed); handled_by is never a participant |
| cp_mission_tests | The admin test log, with def_hash (002: which version a test covered) |
| cp_audit | One staff action: actor and role, category (picks the webhook), action, target, old and new value, reason, the actor's license (008); indexed by target and action and by action and time (017) |
| cp_profile_reports, cp_commendations | Profile reports (the reporter is never shown to the reported officer) and commendations (004) |
| cp_mission_calls | One mission call (code MC-nnnn per day, area, outcome, who posted, paged, claimed, claimants, reason; 005); department = the lane that posted it, NULL = server-wide (013) |
| cp_item_rewards | One item reward (006); stays empty while Config.Rewards.enabled is false |
| cp_settings, cp_settings_history | A setting an admin changed in game (key path, {"v": value} or {"none": true}; no row = config.lua) and every change, reset, switch and revert with old and new value (007, 008) |
| cp_badge_overrides, cp_dept_funding, cp_admin_jobs, cp_admin_requests, cp_staff_notices, cp_storage_meta | Badge grant/block overrides, department funding deposits (pending before the deposit), bulk jobs (their id is the void_batch), request ids (one money or bulk action acts once), staff notices, the storage generation marker (008) |
| cp_pvp_pairs | The anti-farm pair ledger (009): one row per officer and suspect of a closed live or volunteer case, an admin's block, exclusion or suspension, a duty-off time, and volunteer strikes and strike blocks (vol_strike, vol_block while Config.RealPlayers.volunteer.saveStrikes is on); empty until such a thing happens; case and duty rows kept for Config.RealPlayers.pairLedgerDays |
| cp_dept_controls | One department (or '*' server-wide) and Mission control a supervisor or admin changed (011); no row = the config value; a row past expires_at is ignored, also after a restore |
| cp_pvp_cases | One closed live or volunteer case as the Real suspects screen reads it, never a position (016); only the newest Config.RealPlayers.casesKept, none older than pairLedgerDays, while Config.RealPlayers.saveCases is on |

- Only rows with state = 'completed' are summed (service record, boards, goals, bounties, badges); voided runs stay for audit but are left out of every board.
- A type with no cp_type_payouts row uses Config.MissionTypes' payout; the Weekly Boss uses Config.Events.weeklyBoss.payout until an admin sets a mission payout.
- Published custom missions load from their Lua files; the database keeps drafts, metadata and edit locks.
- At each daily reset runs older than Config.Retention.runArchiveMonths (12) move to the archive and audit rows older than Config.Retention.auditDays (180) are deleted (0 turns either off); mission calls are kept Config.Retention.missionCallDays. XP and badges live in cp_officers and cp_badges, so archiving never changes them or the all-time board.
- Every table works the same with the database off (the saves folder).

Database upgrades

Crimson-Police creates and upgrades its own tables: an update never needs a manual SQL import and never wipes history, boards, payouts or custom missions.

- With Config.Database.enabled = false the same migrations build the same tables as JSON documents in Crimson-Police/saves/, run by an engine inside the resource with the same queries; the owner backs up that folder, and /CrimsonPoliceAdmin storage copy database-to-files | files-to-database moves the data.
- Every schema change is a new numbered file in sql/migrations/; a released file is never edited. On start modules/migrations/ creates cp_schema_migrations if missing, runs every unrecorded file in order (split at each ; that ends a line, one statement at a time; no ; in a comment or string) and records each. The console prints "Crimson-Police database at version N" (database off: "saves folder at version N") and each file applied.
- A failing statement stops the runner: it prints the file, the error, the fix and `ensure Crimson-Police`, and the resource stays started in a failed state (FXServer refuses a self-stop): every request gets err.not_started, nothing touches the store, and only `CrimsonPoliceAdmin check` and `CrimsonPoliceAdmin storagemode reset` (also `storage mode reset`, answered at once without an audit row) work in the console. Migrations are safe to run again (IF NOT EXISTS on tables, columns and indexes).
- Migrations only add tables, columns with defaults and indexes; they never DROP or TRUNCATE or delete rows of runs, officers, seasons, badges, payouts, disputes, audit, tests or custom missions; a changed column is a new column with the data copied. The saves folder takes CREATE TABLE [IF NOT EXISTS], ALTER TABLE t ADD [COLUMN] [IF NOT EXISTS] ... [FIRST | AFTER c], ADD [UNIQUE] INDEX/KEY [IF NOT EXISTS] [name] (cols), several ADDs in one ALTER, and CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON t (cols). A NOT NULL DATETIME or DATE column added to a table with rows needs a DEFAULT (no zero dates).
- With the database on, the runner first needs JSON_VALUE that reads a JSON null as NULL (MariaDB 10.3+, MySQL 8.0.21+; Qbox asks for MariaDB 10.9+ and does not support MySQL): an older server fails the start before any table is touched, naming the server and the fix; MySQL starts with one warning. After the migrations every cp_ table that is not utf8mb4 is switched once (JSON columns kept binary); `storage copy files-to-database` does the same before it writes.
- Updating the resource: replace the code, keep config/, logos/, missions/custom/ (and saves/ with the database off). A custom mission file that goes missing is rewritten from storage on start.

## Architecture, folders & events

The folder layout, the feature folders, the module APIs and every net event, callback and action are in docs/dev/ARCHITECTURE.md (§1 folders and load order, §5 modules, §7 blocks, §8 events, callbacks and actions). The rules that shape the whole resource:

- The server owns runs, draws, scaling, points and cash; the client runs objectives and reports progress, which the server validates before awarding anything. Every feature has its own folder (modules/<feature>/, blocks/<block_id>/) that exposes one global table (e.g. CP.Cash) and keeps everything else local.

- Only modules/integrations/* call qbx_core, sc-police, sc-dispatch, sc-ambulance, sc-multijob or Renewed-Banking or read their tables (ox_lib, ox_target, ox_inventory and oxmysql are called directly). Qbox only: the qbx_core exports and events in the Appendix, never exports['qb-core'], GetCoreObject() or QBCore.Functions.

- Only modules/alerts/ writes the crimsonArena state bag; only modules/permissions/ decides whether a role may do an action, and every crimson-police:server:sup:* and crimson-police:server:admin:* event re-checks the sender's role and Config.Permissions on the server.

- A block's server.lua creates and deletes that step's networked NPCs and vehicles and validates its objective events; its client.lua shows markers, blips, ox_target options and UI and, on the run host's client, runs the NPC AI. If the run host leaves, the next participant becomes host; if nobody is left, the server deletes everything.

- Mission files are read as data with LoadResourceFile (never run): the built-ins in missions/builtin/index.lua and every published custom mission, so /CrimsonPoliceAdmin reload updates server and clients without a restart. Every module waits for CP.Migrations.ready() before its first query. Every folder the resource writes ships with a .gitkeep (the server cannot create folders on Linux).

- With Config.Debug = true, each module prints its own tagged lines, e.g. [crimson-police:cash].

Exports

| Export | Side | Purpose |
|---|---|---|
| IsOnMission(src) | Server | True from the moment the player's run is Accepted until it ends |
| GetDepartment(src) | Server | The player's department key, or nil |
| GetAvailablePolice() | Server | Read-only: the on-duty officers who could answer a crime (Config.RealPlayers.liveCrime.availablePolice) and a count per department; nil while Config.RealPlayers.liveCrime.enabled is false |
| OpenTablet() | Client | Opens the Officer UI with the same checks as /CrimsonPolice |

Server-only events (other scripts listen with AddEventHandler; no server id or position in either): crimson-police:server:liveCrimeEnded when a live case ends (Config.RealPlayers.liveCrime.endEvent: the reporting script's crime names, how the run ended, each suspect's outcome by citizenid, the counts of suspects caught and officers), and crimson-police:server:volunteerEnded when a volunteer's mission ends (Config.RealPlayers.volunteer.endEvent: his citizenid, the mission id and type, his role, the mode, his outcome, why his part was voided, whether officers reached him, how the run ended, the officer count).

There is deliberately no export for awarding points: only goal rewards and an admin's logged manual award add points outside a run.

## Settings changed in game

An admin can change every setting of config/config.lua and config/blocks.lua in Admin UI → Settings, so the owner never has to edit a file:

- Who: admins only (the openAdmin permission). The server checks every change again; officers and supervisors never see the screen.
- What: every key of the two files, including the shipped defaults, the department tables, point and pay settings and the Mission Builder ranges. Locked (config.lua only): Config.Database (the changed settings are stored there) and Config.AdminAce and Config.QboxAdmins (who is an admin). Webhooks are server.cfg convars, never settings.
- Storage: one row per changed setting in cp_settings (key path and JSON value), through the migrations, so it works with the database on and with the saves folder. A changed setting wins over config.lua; a setting with no row follows config.lua. Reset deletes the row and puts config.lua's value back; Reset all deletes every row. Setting a value equal to config.lua's is a reset.
- Checking: a value must have the kind and shape of its config.lua value (number, whole number, text, true/false, colour, vector, list, table with the same fields), stay inside a known range (the blocks.lua { min, max, default } triples keep min ≤ default ≤ max; chances stay 0–1; positive numbers stay positive; penalties stay negative), and pick an existing option. A Mission Builder export folder outside missions/custom is refused. A saved value that is no longer allowed (after an update) is ignored with one console line and config.lua's value is used until an admin changes or resets it.
- When it applies: at once for everything read at the moment of use (mission desks too: every client makes its desk zones again). Command names, default keys, the locale, Config.Time.resetHour and Config.Leaderboard.weekStartsOn are read at start: a change is saved and used after the next start, and the screen says so. A change to what the mission loader reads (Config.Blocks, MissionTweaks, mission types, bonuses, Mission Builder limits) reloads the missions; runs already going keep their definition. The Settings screen tells the owner to restart Crimson-Police (txAdmin or the server console); it never restarts the resource itself.
- Every client gets the changed settings at start and after every change.
- After each change the Config health check runs again and its result is shown. Every change is in the audit log (who, when, the setting, old → new), which the screen lists as its history.
- Mission switches: Admin UI → Missions has an on/off switch for every mission and for each location of it (Config.DisabledMissions and Config.DisabledLocations, saved the same way). Off stops new draws everywhere (Mission Board, mission calls, Cross-Department Missions, the Weekly Boss); a run that is already going finishes. A mission whose every location is off is never drawn.
- Also locked (config.lua only): the tablet title and the two command names, the call-id prefixes Config.Calls.npcCallPrefix and ownRunCallPrefixes, and each bonus's each, block and engineOnly. The real-call, alert, start-route and downed numbers of Hard rules 15-18 have known ranges (for example Calls.dodgeWindow 10-300 s, Route.maxDrift 200-5000 m); the rules themselves are never a switch, apart from Route.required (Hard rule 17, the owner's switch: an on/off gameplay rule, not a money switch).
- A bonus's kind (points or pct) changes only together with its value, in one save: points are whole numbers from -500 to 500, pct from -1 to 1, and a bonus stays a bonus and a penalty stays a penalty. A reset puts both back.
- Point values (mission type points, bonus values, the scoring rules, Type of the Day, modifiers, the Weekly Boss points, the cross-department and scaling multipliers, goal and bounty points) are marked as such: a change applies to runs that end after it (a run going now may end with either value; past rows keep their points) and also posts a notice to the flags webhook.
- Money switches: Config.Cash.allowUnfundedRetry, allowCapTopUp, allowPayAgain, restoreForfeited, allowAddFunds, allowClawback, allowManualCash and Config.Rewards.allowTakeBack all ship false. Turning one on needs the typed word ENABLE, which the server checks too; every change is audited and posts to the audit webhook (a full webhook queue never drops it). Turning one off needs nothing.
- Lists of tables have row editors with the same checks as the raw editor: Builder.noBuildZones (label, centre, radius 10-500 m; the two Crimson-Arena zones may grow but never move, shrink or go), Downed.dropOffs (1-10 points), MissionCalls.areas (unique keys, centres inside the map), Scaling (1-10 rows, maxParticipants rising, the last covering Limits.maxUnitSize, known tiers), Recognition.levels (the first at 0 XP and level 1, both rising, the shipped badge colours) and Profile.avatarPresets (the pictures the UI ships).
- Names (Config.Labels): an admin may give an English name to an offence, a commendation kind, a badge, a bonus or a penalty (custody.offence.<id>, profile.commend.kind.<id>, badge.<id>, bonus.<id>, penalty.<id>; 1-64 characters, no markup). A name changes text only, never an id, points or logic; it is read before locales/en.json everywhere. This is not a language: English stays the only one.
- History: every change, reset, reset all and switch also writes a cp_settings_history row with the full old and new values (none = config.lua's), who (citizenid and license) and why, kept as long as the audit log. Other modules add their own cross-field checks (validators) that the raw editor and every structured editor share.

## Full admin control

Everything an admin may want to do is a button in the Admin UI (no config edit, console or database access), apart from the three console ways back in for when the Admin UI cannot open (CrimsonPoliceAdmin settings …, CrimsonPoliceAdmin storage …, set cp_settings_safe 1). Who is an admin does not change: the AdminAce ace, Qbox admins while Config.QboxAdmins is true, and the server console. Every admin is equal; supervisors get no new power. These rules apply to every admin action of this section:

- Admins and the console only: every action has an admin-only permission key (officerRecords, pointsAdjust, bulkVoid, restoreRun, progression, antiFarmOverride, liveRuns, editBuiltins, missionAdmin, boardsAdmin, payments, rewardsAdmin, deptFunds, departmentsAdmin, storageAdmin, playerSupport, recordMove, cleanup) that no Config.Permissions switch can give a supervisor. The server checks it on every action and every read.
- Reasons, typed words, previews: a reason (1-255 characters) where the action changes a record; a typed word for dangerous ones (VOID 12, ENABLE, the citizenid, the amount); a preview of the exact effect for bulk actions, valid for 120 seconds and refused when the data changed since.
- Never your own records: an admin can't correct, pay or adjust any character of their own licenses (every character of one player: Qbox stores a character under the player's license: or license2: identifier), nor a run one of them took part in, live or archived. When a target's license can't be found, money and point actions are refused. The console is exempt.
- One request, one action: every money and bulk action carries a request id; a double click or a resent request acts once and gets the first answer. Two admins (or an admin and an automatic job) never both act: a change names the state it expects and does nothing when someone changed it first.
- Audit: every action writes cp_audit (with the acting player's license, so every character of one player can be found) before any money moves; a money action whose audit row can't be written moves nothing. Bulk actions write one line per row and one summary line that posts to the webhook. Rate limits and daily limits are counted from saved rows, so a restart never resets them.
- Bulk jobs: one at a time server-wide, in batches of 50 rows, their progress shown to admins only; a job a crash interrupted is finished (or stopped) at the next start. The nightly archive and the forfeiture job wait for a running job, a storage copy, a backup or a restore.
- Maintenance lock: from the start of a storage copy, a storage switch or a backup restore until the owner restarts Crimson-Police (a storage copy into the store not in use, or one refused or stopped before it wrote anything, ends the lock at once with no restart), no new run, mission call claim, test run or operation starts, payments and scheduled jobs wait, and every action but the status reads is refused; a banner says so on every tablet. When the work is done the Admin UI and one console line say "Restart Crimson-Police now from txAdmin or the server console": Crimson-Police never restarts itself. A store another one took over from (after a storage switch) stays locked and pays nothing until an admin uses it again. A backup restore that stops part way (or a server that stops during one) puts the money state back and keeps the lock, also after a restart (Config.Backups.holdAfterFailedRestore), until a restore works: the banner names the automatic backup to restore, and that restore is the one action the lock allows.
- Backup restore: every part of the backup is read before anything changes (a missing or damaged part, or rows without a column this version needs and has no default for, refuse the restore and change nothing); a backup made before a migration that added a column with a default gets that default. Keep N never removes the backup being restored. Money and voids only move forward: a payment made after the backup stays paid, a given reward stays given, and the officer (after a record move), the void and the flag of every row that is or can still be paid are the live ones.

Owner decisions (each with its undo):

| # | Decision | Ships | Undo |
|---|---|---|---|
| D1 | Point values are settings an admin may change (logged, resettable, revertible); a logged manual award may also be a deduction (a signed row) | on | Config.AdminControl.pointAdjust = false; point settings reset to config.lua |
| D2 | Corrections are voids: an officer's, an operation's or a board window's rows may be voided as one batch, always restorable; there is still no wipe | on | Undo the batch |
| D4 | Built-in missions can be edited in the Mission Builder as an override with the same id (leaderboards, history, cooldowns, payouts, tests and switches keep working); Reset to original removes it, and the Admin UI says when an update changed the original | on | Config.AdminControl.editBuiltins = false; Reset to original |
| D5 | Departments can be added, turned off and (when unused) deleted in game; a turned-off department's unfinished pay still pays from its account | on | turn it on again |
| D6 | Anti-farm overrides per officer (clear cooldowns, more completions today, another boss attempt, first-run bonus again, forgive streak days, add run time, treat a free abandon as a normal one), each with a daily or weekly limit in Config.AdminControl counted from saved rows | on | set the limit to 0 |
| D7 | Money outside the normal flow: retry unfunded payments, pay the part the daily cap cut, pay a stuck payment again, pay forfeited cash after all, add funds to a department account, take paid cash back, pay an officer by hand, take an item reward back. All ship off (money switches, ENABLE to turn on) | off | turn the switch off |
| D9 | Testing is optional for every mission and every role | on | Config.Builder.requireTestToPublish = true |
| D10 | Admins may rename offences, commendation kinds, badges, bonuses and penalties (Config.Labels, English text only) | on (empty) | reset Labels |
| D11 | An admin may move a re-created character's history to the player's new citizenid (same license, logged, undoable; rows keep their department) | on | Undo move; Config.AdminControl.recordMove = false |
| D13 | The maintenance lock above (not a pause and not a switch: it always ends in a restart by the owner) | on | - |

Not built, by the owner's decision: an in-game admin list, root or limited admins and admin groups (who is an admin stays in server.cfg and config.lua); a restart from the tablet; Discord webhook links set in game (they stay server.cfg convars; the Admin UI shows only whether each is on and the line to paste).

## Config

Every threshold in this spec is a value in config/config.lua, in config/blocks.lua for Mission Builder settings, or, for per-mission values, in that mission's file, so the server owner can tune the system without touching code. If this document and the config disagree, the config wins. The listing below is config/config.lua exactly as this build ships it (English only: Config.Locale stays 'en'). It is laid out like the Admin UI in six parts (General, NPC missions, Player vs police, Police teamwork, Economy and rewards, System); each block keeps its own banner, which names its Settings section, and the Settings All view lists the sections in the file's order. It opens with a CONTENTS comment listing the parts and their blocks, and each part heading ends with a "Usually changed here:" line. Every key of config.lua and blocks.lua has a description in Settings (checked by tests/settings_spec.lua): the comment lines right above it and the comment after it on its line; a key with neither reads the legend of the nearest table above it (comment lines of the form "field: text", each going on over the lines after it up to the next), else the comment of its line (a field of a one-line table such as { kind = 'points', value = 10 }). A settings.desc.<path> locale key still wins over all of these.

The settings themselves are not copied here: [config/config.lua](../../Crimson-Police/config/config.lua) holds every
setting, each with a plain-English comment (the description Admin UI → Settings shows), and
[config/blocks.lua](../../Crimson-Police/config/blocks.lua) holds the range and default of every Mission Builder
setting, laid out like the Mission Builder tables. tests/docs_spec.lua checks that every Config key this spec names
exists in config.lua as shipped.

## Example files

Copy these shapes exactly. Every mission file, built-in or custom, contains one RegisterMission({ ... }) call of plain values (it is read as data, never run); the coordinates below are placeholders.

Built-in missions: every file in Crimson-Police/missions/builtin/ is the reference shape (for example gang_shootout.lua: the fields of Mission catalog, then locations, objectives with their block settings, scaling, items, bonuses and penalties; the common penalties always apply and there is no payout field).

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
    -- ...Config.Builder.minLocations or more
  },

  objectives = {
    { block = 'hostile_waves', label = 'Clear the dock', minSeconds = 45, waves = { 6, 6 },
      weapons = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL' }, accuracy = 30, armour = 10 },
    { block = 'interact_points', label = 'Seize the shipment', minSeconds = 6, points = 'evidence',
      progress = { label = 'Seizing crates', duration = 6000 } },
  },

  scaling   = { 'objectives.1.waves' },
  items     = {},
  bonuses   = { { id = 'no_participant_downed', pctOfPoints = 0.10 } },
  penalties = {},
})

## Anti-exploit & fairness

No client message can award points or cash directly: the server re-checks every objective and flags anything that looks impossible.

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
| Joining a unit or operation only for the multiplier or cash | With 2+ participants each must stay within the objective's presence range (below) for 70% of the run, else he keeps the result with 0 points and $0 and his row is flagged |
| Inflating the tier with idle participants | 3 minutes after In progress anyone not yet at the start is removed as Abandoned (idle) and the tier recalculated (only down) |
| Off-duty, suspended or non-police players | Active job, duty, Crimson-Police suspension and SC-Dispatch suspension are checked on accept, on join and on every objective |
| Switching job mid-run with sc-multijob | That participant is Abandoned (type cooldown applies); the run continues for the rest |
| Staying on a mission during a real call | Responding to, or being assigned, a real call ends the run automatically; supervisors can also force recall |
| Payout changed mid-run | The base payout is locked at accept; the tier is set at the start and can only go down |
| Supervisor payout abuse | 50–200% of the config payout, once per 30 minutes per type, with a reason, audited and posted; admin-set types are locked |
| Reviewing your own runs | Runs of the current character never show in the Review Queue; runs of his other characters may, but every action on them is refused; such a dispute goes to another supervisor of the department, else an admin |
| Easy custom missions built to farm | Allowed lists, minimum objective times, bonus caps, the optional test (Config.Builder.requireTestToPublish), neutral star multipliers; every publish goes to the builder webhook; admins archive or roll back |
| Double cash payments | One payment per participant per run: the row is claimed (paying) before money moves, a final status is never paid again, and the bank entry carries CP-<run_uuid>-<citizenid> |
| Hand-editing a payout into an exported Lua file | Ignored, with a console warning; payouts only come from the Payouts screens |
| Disconnect abuse | Failed (partial points, no cash) with the type cooldown (Weekly Boss: its mission cooldown and that week's attempt, no type cooldown); the run continues |
| Friends or bystanders clearing a mission for you | A mission NPC killed by a non-participant (GetPedSourceOfDeath, or the driver of the vehicle) flags the run outside_help after Config.AntiCheat.outsideKillsToFlag kills, holding points and cash; the Review Queue names him |
| Using test runs to farm | Only admins can start them, and nothing in a test run is saved or paid |
| Farming mission calls | A claim runs every accept check; only leaders claim; one claim per 1.5 s per player; caps and cooldowns apply; a re-dispatched call excludes the old claim's members; staff-created calls are rate-limited and audited |
| Winning claims by connection speed | The 1.5-second claim window ranks by distance to the area, then fewer recent claims |
| Faking police actions or facts | Server-checked begin and finish (Police actions & decisions); truths never leave the server; facts go only to participants; an unseen `stunned` report adds a staff note (Config.AntiCheat.stunNeedsProof 'flag', shipped), flags the officer ('hold') or is refused ('strict') |
| Guessing the truth instead of doing the work | Contacts carry no demeanour or combat data on the client; weapons at the draw, cues only when they start; grading as in Police actions & decisions |
| Reading the truth from the client | The leak spec (tests/field_contact_spec.lua) checks every state set, weapon give, client event and push during a full field_contact run |
| Farming arrests and stats | One arrest per person; wrongful arrests never count; stats, goals, bounties and badges count completed rows only; one scoring event per act |
| Staff steering calls to themselves | Page refused for the issuer's own unit; the issuer's unit can't claim a paged or created call; no rapid response on staff calls; audited |
| Picking the mission through a narrow area | A call names an area to a viewer only when their eligible pool there has 2+ missions and 3+ locations; otherwise it draws as the board does |
| Using sc-police /imp to skip a chase | A read-only listener: a participant's /imp on a run vehicle fails the objective and flags the run (sc_impound), and is never a lawful disposition; a removed car never counts as stopped |
| Griefing a run with /imp from outside | A removal by a non-participant or with no record ends the run as not counted (no points, cash, cooldown or penalty) and audits the sender; nobody on the team is blamed |
| /imp reaching a player's car through a matching plate | Mission plates use the reserved pattern and are rerolled when player_vehicles has them |
| Leader putting members on a run they didn't want | Ready check; decline or timeout costs nothing |
| Kicking a partner to take their share | Kick, make leader and disband only work before a type is accepted |
| Commendation inflation | Own department only, never yourself or your own run, 3 a day, 7-day same-kind cooldown, audited, zero points |
| Offensive pictures or bios | Links off by default, host allow-list, approval, optional bio approval, banned words, Report profile, rate limits, audited clears |
| Item reward farming | Off by default; admin config only; deterministic rolls; held and forfeited with the run; daily item and value caps; presence share; never in the arena |
| Opening the tablet at a desk from afar | The server checks the desk box with server-side coordinates |
| Boosting the tier with friends who then leave | Leaving by choice, disconnecting or never arriving shrinks the NPCs to come and drops the pay tier; only a real call, force recall or going down keeps it (Config.Rescale.keepPayTierFor) |

Presence range (runs with 2 or more participants): each participant must stay within the current objective's range for 70% of the run (Config.AntiCheat.presenceShare), measured per block:

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
| field_contact | The nearest contact not yet decided | 150 m |
| process_scene | The nearest body, or the scene marker | 150 m |

A mission may give any objective its own presenceRange (the builder: 50–800 m per block); the defaults are in config/blocks.lua, and Config.AntiCheat.presenceRadius (150 m) is used only for a block without one.

Flagged runs are held off the boards, with their cash, until a supervisor approves or voids them, each with its flag_reason. Three voided runs in 30 days suspend that officer from Crimson-Police for 7 days (Config.AntiCheat).

Mission controls (rules 11.1; every value, bound and per-day limit is in Config.MissionControls)

- A supervisor changes a control for his own department only while the admin switched it on (Config.Permissions.supervisor.missionControls, the master switch, and the control's own on), only inside the admin's min and max (a department may have its own in Config.Departments.<key>.missionControls), at most once per changeWait per control and department, with a reason, audited with old and new value. Narrowed bounds move a saved value into them at once; switching a control or the master switch off restores the config value at once. A relaxing control never applies to its setter, his other characters or his unit (selfExempt). Admins change any department within the same bounds, in Admin UI → Permissions → Mission controls (per control: the switch, min/max, the value in force with who set it and how long it runs, Reset with a reason; per department bounds and grants).
- Server-wide, outside the master switch, on as shipped (owner decision): cooldownScale (x every mission's cooldown per type, 0 = none) and abandonCooldown (the abandon type cooldown), both read when a cooldown is read, so a change counts at once for running cooldowns and after a restart; noRepeat (false = the draw and a call's pool ignore history), hourlyCap (Limits.maxCompletionsHour) and dailyCap (Limits.maxCompletionsDay, 0 = no cap), read through CP.Draw.limits for the officers concerned (accept checks, board and boss locks, call claims, Home, Live missions); happyHour; clearCooldown.
- happyHour (5–30 min): until it ends no mission has a cooldown for anyone (cooldownScale reads 0) and, when ticked, no-repeat is off; abandon cooldown, caps and cash rules stay; the setter and his unit keep theirs. A timed row (expires_at), so a restart keeps it; afterwards cooldowns count against their real end. One at a time; happyHourPerDay (1) a day on the whole server (any supervisor; admins any). A banner on Home and the Mission Board; admins end it from Admin UI → Live (End now) or Mission controls (Reset).
- clearCooldown (action): clears one mission or type cooldown of an officer of any department from Department Report, never his own character, never while the officer is on a run, with a reason; per officer at most Config.AdminControl.cooldownClearsPerDay by all staff, per supervisor clearCooldownPerDay (5).
- The rest are per department, under the master switch, off as shipped:
  - addRunTime (1–5 min a click): adds time to a running mission of his department from Live Missions, never his own; the run's total with admin additions stays within addRunTimeMax (300 s, never above Config.AdminControl.runTimeAddMax); addRunTimePerDay (10); the fast-finish limit never changes.
  - In a run (read for the leader's unit at accept, locked in run.controls): startTimeout replaces Config.Limits.startTimeout and the mission's own; readyCheck replaces Config.Units.readyTimeout (0 only while its bounds carry canTurnOff = true); timeLimit scales the time limit (fast finish still on the unscaled one); idleCheck is stricter only, never above Config.AntiCheat.idleCheck.
  - difficulty: one of the Config.NpcDifficulty presets the admin lists, for runs the department leads (NPC health, aim, surrender, flee; Config.NpcCombat still caps; points and cash unchanged). unitSize: the largest unit its leaders may lead, never above Config.Limits.maxUnitSize.
  - types: switches types or single missions off for the department (a catalog switch like Config.DisabledMissions): the card shows "Off for SAST by command", accepts and claims refuse a unit with a member of that department (err.type_off_department), a switched-off mission is never drawn for it; other departments and the Weekly Boss unaffected; one type stays on. featuredType: one type shown "Recommended by command", sorted after the officer's favourites; points and pay unchanged.
  - missionBan (action, 1–24 h): from Department Report bars one online officer of his department with a lower grade (never his own license) from missions, with a reason; missionBanPerDay (3). He cannot accept (nor his unit), claim or join a Cross-Department Mission (err.mission_banned / err.member_mission_banned); his board shows "Mission ban until 18:40 (by Sgt Doe)". The tablet stays usable (not a suspension, which stays admin-only) and a running mission goes on. The setter lifts it from the same dialog, an admin from Officers → Today & cooldowns or Restrictions (antiFarmOverride; extend there with missionControls, never past a week from now); all audited under flags. Kept in cp_officers.mission_ban.
  - callLane: the department's own lane of mission calls (gap range, open at once up to callLaneMaxOpen, areas, callable types with weights 0–10), one call at a time, only to idle units all of that department; other departments never see its calls and cannot claim them (err.mc_other_department), nor can the setter's unit (err.mc_own_call). Lane calls count against Config.MissionCalls.maxOpen; the server's flow counts only its own calls against its target. Saved in cp_mission_calls.department; Dispatch tags it "SAST call". staffCallWait replaces Config.MissionCalls.staffCooldown for its supervisors' staff calls (the one who shortened it keeps the config wait).
  - notices: a short notice (noticeMaxLength, 1–30 days) on his department's Home Announcements only; banned words apply; noticesPerDay (5); at most 5 running per department (besides the admins' 5); any supervisor of the department may end one; audited. crossDept { join, places }: keeps its officers out of Cross-Department Missions (err.op_department_out) or caps their places (err.op_department_full, 0 = no cap); never relaxes, so it applies to the setter too.
  - boards { showToOthers, metrics }: other departments see its officers by callsign only (rows, profiles, Home's top 3, picture hidden), and its own officers see only the ticked Rank by tabs (Points always); presentation only. reviewRules { secondVoid, adminOnlyKinds }, stricter only: a supervisor's Void stays pending until a second supervisor of the department voids too (a restart clears it); listed flag kinds go to admins only; admins void at once.
  - twists { offered, ticked }: narrows the accept step of units it leads to the offered twists (among Config.Events.twists) and pre-ticks the ticked ones; another is refused (err.twist_department).
  - typeOfTheDay (choice): picks one type for the next day (never today), once a day (err.tod_picked_today; admins may correct it); that day its officers earn Config.Objectives.typeOfTheDay.multiplier on it instead of the server's type, except the setter and his unit; read back from yesterday's last audit row, so a restart keeps it; switching off drops it at once.
  - happyHourPoints (min = max = 1.0 as shipped): multiplies the final points of a completed run it leads accepted during a happy hour, after the cap and the Type of the Day, fixed at accept (run.controls.pointsBonus); not for the starter of the happy hour or his unit. twistPoints: multiplies each twist's points share, still within Config.Events.twistMaxPoints. Neither applies to test, Cross-Department or Weekly Boss runs.
  - pushMission (action; the Mission choice push exception): in Page a unit (Live Missions, Admin UI → Missions) a supervisor picks one mission of the call's type for a unit of his department (never his own); only that unit is offered the call and sees the mission's name; its leader accepts (every accept rule runs; only the random draw is skipped, the location is still random) or declines; a decline, refused accept or failed ready check ends the call, an abandoned run is never re-dispatched, and the issuer is told. A staff call: no rapid response. pushMissionPerDay (5, from the audit log; admins any); audited as mcPush.
  - awardPoints (action, 1–50 points; owner decision, the Points Hard rule): from Department Report a logged manual award to an officer of his department (online job, else cp_officers.department; offline too), with a reason, never to his own license (license: and license2:). It goes through CP.Corrections.adjust (Config.AdminControl.pointAdjust, adjustDailyLimit and adjustConfirmAbove apply), shows in the officer's history, only an admin undoes it by voiding the row, audited as manualAward with role supervisor; awardPointsPerDay (100, 0 = no limit) in all; admins skip the department and per-day rule.

## Supervisor & admin actions

Admins can always do every action marked Admin. Config.Permissions.supervisor switches the supervisor actions; by default all are on except rolling back missions, breaking edit locks and editing other people's missions. Nobody approves, voids or answers a dispute about a run any character of his license took part in. A /CrimsonPoliceAdmin subcommand also works from the server console.

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
| Manual award | Admin (Supervisor: the awardPoints Mission control, Give points below) | Admin UI → Leaderboards; /CrimsonPoliceAdmin award <citizenid> <points> <reason> | Manual points, stored as a 'manual_award' row |
| Start or end a season | Admin | Admin UI → Seasons & Challenge; /CrimsonPoliceAdmin season start <name> or season end | Opens or closes a season and its department challenge |
| Override this week's bounty | Admin | Admin UI → Seasons & Challenge | Replaces the randomly picked bounty for the current week |
| Department Mission controls (Give points, Mission ban, notices, Cross-Department participation, boards, review rules, twists, Type of the Day, points bonuses) | Supervisor (each its own Mission control, own department), Admin | Supervisor UI → Department Report and Mission controls; Admin UI → Officers → Today & cooldowns | As in Anti-exploit & fairness → Mission controls; reason required, audited |
| Department's cash bonuses | Supervisor (happyHourCash and twistCash Mission controls) | Supervisor UI → Mission controls | x the cash of runs accepted during a happy hour, x each twist's cash, inside the admin's bounds, twists still under twistMaxCash; never test, Cross-Department or boss runs; under the daily cash cap |
| Department's goals | Supervisor (goals Mission control) | Supervisor UI → Mission controls | Which of the admin's daily and weekly goals his officers draw from, from the next weekly reset; points unchanged; never the setter's own goals |
| Suspend or unsuspend an officer | Admin | Admin UI → Officers; /CrimsonPoliceAdmin suspend <citizenid> <days> | Blocks an officer from Crimson-Police for that many days; 0 days lifts it |
| Publish a draft (tested or not) | Supervisor (own missions; any mission with builderEditAny), Admin | Supervisor UI → Mission Builder; Admin UI → Missions | Makes the draft the live version and writes its Lua file |
| Archive or restore a custom mission | Supervisor (own missions; any mission with builderEditAny), Admin | Supervisor UI → Mission Builder; Admin UI → Missions | Removes a custom mission from its pool, or puts it back |
| Roll back a custom mission | Admin (supervisors only with builderRollback) | Admin UI → Missions; Supervisor UI → Mission Builder when allowed | Restores the previous version from its .bak file as a new version |
| Break an edit lock | Admin (supervisors only with breakEditLock) | Admin UI → Missions; Supervisor UI → Mission Builder when allowed | Unlocks a mission someone else is editing; their changes since the last autosave are lost |
| Reload mission files | Admin | Admin UI → Missions; /CrimsonPoliceAdmin reload | Reloads built-in and custom mission files without a restart |
| Run the start-up check again | Admin | Admin UI → Permissions → Config health; /CrimsonPoliceAdmin check | Runs every Config health check: the console lists every line, in game a toast gives the counts |
| Withdraw, page or create a mission call | Supervisor (missionCalls; never paging their own unit), Admin | Supervisor UI → Live Missions → Mission calls; Admin UI → Missions; /CrimsonPoliceAdmin missioncall <type> [area] | See Dispatch (mission calls) → Supervisor and admin controls |
| Commend an officer, or revoke a commendation | Supervisor (issueCommendation; own department, never themselves or a run they took part in, 3 a day), Admin | Supervisor UI → Department Report; Admin UI → Officers | A citation with no points and no cash; revoking needs a reason |
| Moderate a profile | Supervisor (reviewProfiles, their department), Admin | Supervisor UI → Review Queue → Profiles; Admin UI → Officers | Approve or reject a pending picture or bio, clear a bio or picture, clear or dismiss a report; reason required |
| Remove a joiner from a Cross-Department Mission | Supervisor (launchCrossDept), Admin | Supervisor UI → Cross-Department Mission | Before the start only; reason required |
| Change or reset a Mission control | Supervisor (missionControls, own department, inside the admin's bounds, once per Config.MissionControls.changeWait per control, a grant when one is set), Admin (any department, bounds still apply) | Supervisor UI → Mission controls; Admin UI → Permissions → Mission controls | Changes a rule for that department, or puts it back to the config value; reason required |
| Start a test run | Admin | Admin UI → Testing; /CrimsonPoliceAdmin test <missionId> [tier] [location] | Starts any mission at the chosen location and tier; nothing is saved or paid (see Admin test mode) |

Every action is written to cp_audit (who, role, action, target, old and new value, reason, time) and posted to its webhook: payout changes and admin actions to cp_webhook_audit, flagged runs, voids and disputes to cp_webhook_flags, Mission Builder actions to cp_webhook_builder, and Cross-Department Missions to cp_webhook_operations (see Config).

## Admin test mode

Admins can start any mission on demand, pick its location and tier, and play or step through it to check that it works. Nothing in a test run is saved or paid. The Mission Builder's test run of a draft uses the same mode.

Starting a test: Admin UI → Testing, or /CrimsonPoliceAdmin test <missionId> [tier] [location] in game.

- Any mission can be tested: built-in, custom (published or archived), or turned off (Config.DisabledMissions or its switch), at any location, also one turned off. Drafts are tested from the Mission Builder. Testing is optional: nothing waits for a test, and no screen blocks or warns about an untested mission.

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

Check spawn points (Config.Testing.spawnCheck): an admin's own game checks every point of every mission, one mission or one location, so bad ones can be fixed in the files.

- The server lists every point of a location with what stands there (a person, vehicle or object; a marker where officers stand; a path point), from each objective's point kinds (the escort truck at its route's first point), and notes people, vehicles and objects closer than Config.Spawning.minDistance (40 m) to the start or to the objective before.
- The admin's game visits each location frozen, unseen and unhurt (the screen fades; the map loads for up to sceneTimeoutMs, 8 s), notes which spawns within 200 m it sees from the start, then judges every point with the ground probe (markers and path points as a person, without the wall check). A point further than moveWithin (150 m) is checked from right over it. Route points only with routes = true.
- The server keeps its own coordinates and writes one console line per bad point (also System → Problems), e.g. spawn check: gang_shootout #4 spawns[7] (1153.75, -3169.50, 5.88) UNDERGROUND ground 6.40 (-0.52) [ped]; a point the probe could snap reads HEIGHT OFF. The last report per location stays until the restart.
- It spawns and moves nobody else. Refused in the arena, on a mission, in a vehicle, while down or while one runs; Stop ends it after the current point. Afterwards he is back where and as he was; if Crimson-Arena takes him meanwhile he is not moved again; a run of his starting meanwhile ends the check at once (Start test is disabled and the test teleport refused while it runs).
- Admin UI → Testing: "Check spawn points" (and a check item per location row): all, one mission or one location; Start and Stop; progress; results with mission, location, point, what is there, x y z, ground, height, the result with a hint and notes; problems only by default. "Teleport here" puts the admin on the ground at a point (position from the file, audited; spawnCheck.teleport; not during a check). "Copy report" copies the console lines and the locations that could not be checked. Results stay while the tablet is closed. Hidden while Config.Testing.enabled or spawnCheck.enabled is false.

Every test start is written to the audit log. The options are in Config.Testing.

## SOP: rules of use for officers

Crimson-Police is a downtime activity. Real calls and real players always come first, and misuse is handled like any other SOP violation. Live crimes and volunteer cases are real RP with real players: the server rules on force, combat logging and staging apply.

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

Cases with real suspects (live crimes and volunteer suspects, both off by default; docs/OWNER_GUIDE.md section 6.2 "Rules for cases with real suspects" gives the same rules to paste into a server's rules):

- Least force. Tase, tackle and cuff; shooting a suspect who never had a gun or running one over on foot is a penalty (rs_unarmed_shot, rs_ran_over) and a flag. A suspect cuffed while down counts only Config.RealPlayers.neutralisedShare of a detain, one cuffed while AFK nothing: no points come from hurting a player.

- No live tracking. Officers work from the reported place and the "last reported" points; asking anyone outside the case where a suspect is, is a violation.

- No case against yourself or a friend. Never take a case against your own characters or someone you play with; the server refuses most of these and flags the rest for review.

- Suspects play it out. Crew members and volunteers may run, hide, talk and give up; logging off, switching character or entering an instance to escape counts as leaving and is shown to staff. Volunteers say yes only when they can play now, reach the waypoint in time and stay in the area they are given; a no costs nothing, a no-show or walking away is a strike, and Stop or Cancel this case on the volunteer command is always available.

- Staff decide from the case timeline. Reports about a case are decided from its timeline, damage ledger and flags on the Admin UI Real suspects screen; nobody reads or reviews a case they were a suspect in.

Discipline ladder: verbal warning → run voided (points removed, held cash not paid) → 7-day Crimson-Police suspension → removal from the system and a standard write-up.

## Performance, testing & acceptance

The release is accepted when every check below passes on a test server with at least 10 officers of both departments (the in-game run is docs/IN_GAME_CHECKLIST.md; the automated suite is docs/dev/TESTING.md).

Performance targets

- Client resmon at most 0.02 ms idle and 0.10 ms during a run (no per-frame loops outside active objectives).
- Server resmon at most 0.25 ms with 30 officers and a Critical-tier Cross-Department Mission; leaderboard queries under 50 ms.
- The Officer UI opens in under 300 ms; no entity is left behind after any run.

Acceptance checks (each one rule of this spec)

- ☐ Access: on-duty SAST or FIB officers open /CrimsonPolice and start a mission any time; off-duty, suspended, non-department players and an sc-multijob second job cannot.
- ☐ Qbox only: no qb-core dependency, no GetCoreObject or QBCore.Functions in the code.
- ☐ Header: department name and tag, rank and callsign (a /callsign change shows at the next open); every screen, the HUD and notifications are Crimson-Police NUI (ox_lib only for progress bars and skill checks).
- ☐ Departments: BCSO added by config and logo alone gets its name, colours and watermark and joins boards, challenge, invites and builder; the watermark never blocks clicks; a missing logo shows no broken image.
- ☐ Draw: only a type is accepted; the mission is random and never the last one unless it is the only one; abandoning, leaving the route or missing the start timeout cools down the whole type.
- ☐ Route: 120 m off warns after 10 s and abandons after 30 s; back on resets; Recalculate twice; missing reports count as off route.
- ☐ Real calls: assigned or responding ends that participant's run with no cooldown; npccall-… never; un-marking within 60 s applies the cooldown; a partner's person-down call never ends the others' runs; a faked call id does nothing; on a call = can't accept.
- ☐ Alerts: arrived participants' gunfire makes no shots-fired or person-down alert; forced ones clear within 3 s; the flag goes at run end (a downed participant keeps it until pick-up or EMS request); another resource's flag is never removed.
- ☐ Downed: Failed with the type cooldown; no EMS = revived at the nearest drop-off after 15 s with no bill; EMS on duty = an EMS request; hospital:server:RevivePlayer never triggered.
- ☐ Capacity: no shared locations; at 12 runs (or 4 Tactical) accepts are refused with "Server busy"; runs of different missions stay 200 m apart while another location is free.
- ☐ Units and scaling: mixed-department units earn the bonus; invites close at accept; the tier matches the scaling table; waves respect 25 alive and 80 entities without cutting counts; leaves rescale as in When someone leaves mid-run; kick, make leader and disband are refused after accept; a declined ready check costs nothing.
- ☐ NPCs: every participant sees the same ones; the next participant takes over the AI when the host leaves; NPCs never drop weapons; a kill by a non-participant flags outside_help.
- ☐ Cross-Department: the lock hides and refuses every other mission until completed or cancelled; auto-cancel after 30 idle minutes; no relaunch within 30 minutes.
- ☐ Roles: supervisors play like officers and see the Mission List; officers never see missions; each UI shows only its screens and the server refuses actions without the role or switched off in Config.Permissions; nobody reviews a run of any character of his license.
- ☐ Payouts and cash: supervisor limits (no admin value, 50–200%, 30 minutes, reason); admin values survive restarts, resets, re-publishes and reloads; completed runs pay base × tier × twists with a bank entry, never twice; an empty society account pays $0 (unfunded); held cash approved offline pays on the next load-in.
- ☐ Goals, resets and boards: goals award once; resetHour 6 moves Type of the Day, daily goals and the cash cap to 06:00; the weekly board resets Monday and posts the top 3; each webhook convar posts only its category; voided runs leave every board within 60 s; the challenge and bounty follow the configured mode, once; every Rank by metric respects period, filters, minimum runs, privacy, voids and flags; kills never appear.
- ☐ Disputes and flags: flagged or voided runs go to supervisors, failed runs to admins; forged or too-fast events are rejected and flag the run; flagged cash is held.
- ☐ Items: mission items given and removed through ox_inventory; item rewards (when on) roll the same after a reconnect, are held by flags, forfeited by voids, never given in Crimson-Arena, inside the daily caps.
- ☐ Builder: draft, test, publish and complete without a restart; routes saved as road waypoints and driven in lane at the set speed; off-road, 0.8–8 km and no-build checks; Test drive marks unreachable waypoints; only allowed models and blocks.lua ranges; spot checks; publishing needs no test unless requireTestToPublish for a supervisor; one editor, 30 s autosave, the live version kept while editing, lock breaking and rollback; the Lua file is written, reloads as a new version, and a hand-added payout is ignored.
- ☐ Disconnects and stops: a disconnect is cleaned up with the type cooldown (Weekly Boss: its cooldown and that week's attempt), the run goes on; a resource stop removes every entity and alert flag with no cooldown.
- ☐ Missions: every built-in mission and the Weekly Boss complete at every tier they support with correct points, cash and decision ledgers; vehiclePenalties = false never applies the heavy-damage penalty but keeps ramming penalties; presence counts 400 m in a pursuit and 300 m round an escort.
- ☐ Test mode: an admin starts any mission at any location and tier; nothing saved or paid, no cooldown, caps and lock ignored, location still reserved, would-be points and cash shown; test controls only for that admin; Testing shows last results and "Changed since test".
- ☐ Migrations: a fresh database from 001; a new file applied once; a failing one leaves err.not_started with one console line naming the fix and `ensure Crimson-Police`; nothing dropped.
- ☐ Streaks: one missed day a week keeps the streak; a second resets it.
- ☐ Mission calls: only a leader passing every accept check claims; within 1.5 s the nearer unit wins; drawn after the claim, in the area; an early-abandoned claim re-dispatches once without the old claimants; never reaches SC-Dispatch; withdrawn at an operation's launch; no viewer's pool smaller than the board's; the issuer's unit can't claim a staff call, which never earns rapid response.
- ☐ Contacts and custody: the Traffic Enforcement grading (paced and cited = Best; lit before paced = −15 only; stolen cited after the confirm fails); a partner's mid-bar fact is an unknowing mistake; case-failing choices always confirm, never from ox_target; running from an order then caught = Arrest Best; consensual walk-off costs nothing; undiscoverable drugs = Release Acceptable; no lawful fact = never Best; no truth, demeanour or armed flag leaves the server before its behaviour; unlawful searches −15 with findings ignored; a frisk finds weapons only; a released known warrant fails, an unchecked one −15; escort, seat and van hand-over; unsearched armed hand-over −10; tow and van fallbacks after 60 s and AI hand-over; /imp rules and reserved plates; seated people via their door; adopted contacts get their events; Process the scene limits and +15; the Drug Lab breach and toxic fire rules; one person one arrest, one act one bonus, wrongful arrests and unfinished rows count nowhere.
- ☐ Lints: the zone and spawn lints fail as in Location lints; a Builder duplicate of every new mission validates and publishes.
- ☐ Profile: XP follows Config.Recognition.levelCurve with one toast per level and "XP pending review" on flags; avatar, bio, report and commendation rules; personal accents only from the department.
- ☐ Desks open the tablet only within the box plus 2 m for their departments; with requireItem every other way needs the item.
- ☐ Every player-facing text is in locales/en.json; tools/check_contracts.py reports no missing key.
- ☐ With Config.Database.enabled = false every check passes the same way, kept in the saves folder across restarts and moved by /CrimsonPoliceAdmin storage copy.

## Server owner checklist

The settings and choices only the server owner can make are the owner's go-live checklist:
docs/OWNER_GUIDE.md section 7.1 (Before go-live checklist) and section 4 (Settings to check in your other
resources), with the install steps in the root README.md.

## Appendix: integration reference

Use only these calls, only from modules/integrations/, and never edit the resources themselves.

qbx_core (Qbox APIs only, as used by the installed SC resources and Renewed-Banking)

| Call | Side | Use in Crimson-Police |
|---|---|---|
| exports.qbx_core:GetPlayer(src) | Server | The Qbox player object: PlayerData.citizenid, charinfo.firstname and lastname, job.name, job.label, job.grade.level (supervisor check), job.grade.name (rank), job.onduty, job.type, metadata.callsign, metadata.isdead, metadata.inlaststand |
| exports.qbx_core:GetPlayerByCitizenId(citizenid) | Server | Find online officers for invites and payouts |
| exports.qbx_core:GetMetadata(src, key) | Server | The downed check: metadata.isdead and metadata.inlaststand of an online player (src is always a number); on a Qbox without this export the check reads GetPlayer(src) instead |
| exports.qbx_core:GetQBPlayers() | Server | Every online player, e.g. to notify on-duty officers of a Cross-Department launch (a Qbox export, despite its name) |
| exports.qbx_core:GetJobs() | Server and client | Job labels and grade names for the UIs |
| player.Functions.AddMoney(moneyType, amount, reason) | Server | Cash payouts (moneyType = Config.Cash.account). player is the object returned by exports.qbx_core:GetPlayer(src); this is allowed, the QBCore core object is not |
| exports.qbx_core:GetPlayerData() | Client | Current job, rank, duty and metadata for the tablet |
| Event QBCore:Server:SetDuty (src, onDuty) | Server | Going off duty mid-run removes the officer as Abandoned (off_duty) |
| Event QBCore:Server:PlayerLoaded (player) | Server | Pays pending cash and refreshes the stored callsign and rank |
| Events QBCore:Client:OnJobUpdate, QBCore:Client:SetDuty (onDuty), qbx_core:client:onGroupUpdate, QBCore:Client:OnPlayerUnload | Client | Refresh or close the tablet when the job, duty or character changes |
| Table player_vehicles (read-only) | Server | CP.Qbx.plateOwned(plate): `SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1` through the real oxmysql (also in files mode), only to reroll an owned mission plate; on error the reserved pattern alone is used |

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
| Net event police:server:Impound (plate, fullImpound, price, body, engine, fuel, netId) | A second, read-only handler (modules/integrations/sc_police): for a run vehicle it records the sender, the netId and his server-side distance; never triggered or cancelled. sc-police deletes the car on every client after its 5 s bar, checks neither job nor distance and updates player_vehicles by plate, so it is never a lawful disposition |
| /imp and /depot | They pick the closest vehicle with no distance limit, so they can remove a mission car (Police actions & decisions → Impound); officers are told never to use them on mission cars |

sc-dispatch

| Call | Side | Use in Crimson-Police |
|---|---|---|
| Net event sc-dispatch:server:ToggleResponding (callId, isResponding) | Server listener | A second, read-only handler; sent on responding, on a dispatcher's assignment (AutoResponding = true) and on detach. callId is the unique_id, else the row id |
| Table mdt_dispatch (read-only) | Server | Confirms a call is real and active: SELECT unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1, with the number and the string form of callId; an unknown or inactive call is ignored |
| Event sc-dispatch:server:callClearedByOfficer (callId) | Server listener | Remove that call from the responding map |
| playerDropped | Server | Remove the player's responding entries |
| Event QBCore:Server:OnPlayerUnload (src) | Server | A character switch keeps the server id: drop that src's responding entries (and pending lookups); the dodge-rule data stays until it expires |
| Net event sc-dispatch:server:ShotsFired (data: coords, street, zone) | Server listener | The backstop: the call is shots_<src>_<os.time()>; from an In-progress participant within 300 m of his mission, wait 1 s and clear it |
| exports['sc-dispatch']:ClearNotification(uniqueId, jobTable) | Server | ClearNotification('shots_<src>_<time>', { 'police' }) for the current and previous second; a list with police clears it for every job in Config.Police.AllowedJobs (sast, fib, bcso) |
| State bag crimsonArena | Both | With Config.Integrations.CrimsonArena = true, IsInCombatSafeZone() skips shots-fired, person-down and dead calls while state.crimsonArena.active; set with Player(src).state:set('crimsonArena', { active = true, source = 'crimson-police' }, true) |
| exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobname) | Server | Refuse suspended officers |
| exports['sc-dispatch']:AddNotification(data) | Server | Do not use: missions never create dispatch calls |
| Call id formats | — | shots_, panic_, emshelp_, playerdown_ and playerdead_ followed by <src>_<time> (sc-dispatch); emsdown_<src>_<time> (sc-ambulance); npccall-<n>-<time> (sc-npcpolice) |
| Shots-fired exemption | — | sc-dispatch itself skips shots-fired only for on-duty police, bcso and fib, and alerts Config.Dispatch.ShotsFired.AlertJobs (incl. sast, fib) |
| Roster | — | Config.Roster.CommandGrade = 4: grade 4 and up count as command staff in SC-Dispatch |
| Net event sc-dispatch:client:AssignedToCall (info) | — | Not needed: the assigned officer's client also sends ToggleResponding |
| Table mdt_dispatch (read-only) | Server | Dispatch screen strip: SELECT priority, COUNT(*) AS n FROM mdt_dispatch WHERE active = 1 AND (unique_id IS NULL OR unique_id NOT LIKE ?) GROUP BY priority, with Config.Calls.npcCallPrefix (LIKE-escaped) followed by %; cached 15 s; hidden on error |
| Table employee_incidents (read-only, optional) | Server | Config.Profile.showMdtCommendations: SELECT title, issued_by, UNIX_TIMESTAMP(created_at) AS ts FROM employee_incidents WHERE citizenid = ? AND type = 'commendation' ORDER BY created_at DESC LIMIT 10; shown tagged "MDT". sc-dispatch also writes a commendation row on a promotion |
| Dispatcher mode | — | No export exposes it; Crimson-Police does not read it. Mission calls exist only on the tablet, so AssignedOnlyAlerts does not affect them |
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
| Net event hospital:server:EMSDownAlert (street) | Client → server | Sent from the downed officer's client after his flag is removed; SC-Ambulance makes an emsdown_<src>_<time> call (it ignores flagged or not-down players) |
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

ox_inventory (standard API): Search(src, 'count', name), Search(src, 'slots', name, metadata), CanCarryItem(src, name, count, metadata), AddItem(src, name, count, metadata), RemoveItem(src, name, count, metadata, slot), Items(); client event ox_inventory:itemCount for the tablet item.

ox_lib, ox_target, ox_inventory and oxmysql are used through their standard, documented APIs.

