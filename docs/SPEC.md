# Crimson-Police – Tablet Missions & Leaderboard Spec

Sep 30, 2026 · @John Wood · English only

Crimson-Police is a Qbox police tablet (/CrimsonPolice) with its own custom UI. It gives on-duty SAST and FIB officers random NPC missions by mission type, pays cash through Renewed-Banking and ranks officers on leaderboards. Read Hard rules first: they override every other section, and the files in config/ override any number in this document.

## Hard rules

These rules override everything else in this spec. If another section, example or number disagrees with a rule here, the rule wins.

- Stack: Crimson-Police MUST run on Qbox (qbx_core) and MUST use only these resources: sc-police, sc-dispatch, sc-ambulance, sc-multijob, Renewed-Banking, oxmysql, ox_lib, ox_inventory and ox_target. It MUST recognise calls made by sc-npcpolice without calling it. It MUST NOT require, bridge to or edit any other resource. When Config.LiveCrime is on it MAY listen to Crimson-Contracts' server-only lifecycle events (crimson-contracts:server:*) and it offers the read-only export GetAvailablePolice; it never requires Crimson-Contracts.

- Qbox only: all framework access MUST go through exports.qbx_core, the Qbox player object it returns (for example player.Functions.AddMoney, which is Qbox's own API) and the events qbx_core fires. Crimson-Police MUST NOT use the QBCore core object (exports['qb-core']:GetCoreObject(), QBCore.Functions) or list qb-core as a dependency, even though Qbox ships a QBCore compatibility layer.

- Names: the resource folder MUST be Crimson-Police (events, callbacks and tags keep the lowercase prefix crimson-police) and the tablet MUST be titled "Crimson-Police". The officer command MUST be /CrimsonPolice and the admin command MUST be /CrimsonPoliceAdmin. Volunteer suspects use the command in Config.Volunteers.command (default /crimsonheat).

- Access: only on-duty players whose active Qbox job belongs to a department in Config.Departments MAY use the Officer UI. There are no activation requirements: no activity check, no minimum officers online and no quiet timer. Exception (owner decision): a mission type or mission set to 'players_only' in Config.Volunteers is offered only while a volunteer suspect who fits is online.

- Roles: there are exactly three roles: Officer, Supervisor (job grade at or above the department's supervisorGrade) and Admin (ace crimsonpolice.admin, or a Qbox admin, the ace admin that stock Qbox gives group.admin, while Config.QboxAdmins is true). There are no cadet, detective or other roles. Supervisors get the same missions as officers. Ranks and callsigns are read from Qbox, as SC-Police sets them, and are never edited by Crimson-Police.

- Mission choice: officers and supervisors MUST only pick a mission type on the Mission Board or claim a mission call on Dispatch, and the server MUST draw the mission at random after the claim. A call names a type, a priority and an area, never a mission; it names an area to a viewer only when his eligible pool there (after unit size, no-repeat, cooldowns and daily limits) holds at least 2 missions, else "County-wide" from the board's pool, so a call is never narrower than the board. Staff-posted or paged calls draw at random like any other and never go to the issuer's own unit. The Officer UI MUST NOT list, preview or let anyone pick a specific mission, and there is no reroll. Only five exceptions exist: the Weekly Boss event card; a mission launched as a Cross-Department Mission; test runs (Admin test mode and the builder's draft test), never saved or paid; a LIVE call (a real crime reported by Crimson-Contracts: no draw); and a mission pushed to one unit of the supervisor's own department (the pushMission Mission control, owner decision, shipped off; its rules are under Mission controls). A 'players_only' type (Config.Volunteers) draws only from missions that can take a volunteer, still at random.

- Cross-Department Missions: while one is active, every department's Mission Board MUST show only that mission, and the server MUST refuse every other new mission until it is completed or cancelled. Admin test runs are the only exception.

- Teams and scaling: officers from any department MAY team up. Missions MUST scale with the number of participants, and cash MUST scale with the resulting difficulty.

- Cash payouts: every mission pays its mission type's payout × its star multiplier (the Weekly Boss pays its own event payout from config) unless an admin has set a payout for that specific mission. Supervisors MAY change a type's payout only if no admin has set it, and only within Config.Payouts.supervisorRange. A supervisor may raise a cash bonus only inside admin-set bounds (the happyHourCash and twistCash Mission controls), never on test runs, Cross-Department runs or the Weekly Boss, and always under Config.Cash.dailyCap. Only admins MAY set a single mission's payout. Any payout an admin sets is permanent until an admin changes or clears it.

- Points: leaderboard points come from Config.MissionTypes and the scoring rules. Officers MUST NOT be able to change points in game. Supervisors MAY give points only through Mission controls an admin switched on (owner decision), inside the admin's bounds, never for themselves, their other characters or their unit, never on test, Cross-Department or Weekly Boss runs, audited: typeOfTheDay, happyHourPoints, twistPoints, goals (which of the admin's Config.Goals their department draws from the next weekly reset) and awardPoints (a logged manual award through the admin's point-adjust path and its guards). Only an admin MAY change point values: a point setting in Admin UI → Settings (audited) or a logged manual award or deduction (a new signed row, never an edit; see Full admin control).

- Server authority: the server decides draws, scaling, points and cash. The client MUST NOT send point or cash amounts; it only reports objective events, which the server validates.

- Departments: department names, colours and logos come only from Config.Departments. Adding a department there and restarting, or adding it from the Admin UI, MUST make it work everywhere with no code or SQL changes.

- Custom interfaces: the Officer UI, Supervisor UI and Admin UI are separate, custom standalone NUI built for Crimson-Police, together with its Mission Builder, mission HUD and notifications. Each shows only its own screens, and the server MUST re-check permissions on every action. The only outside UI allowed is ox_target's interaction prompts, ox_inventory's own inventory screens, and ox_lib's progress bar and skill check during missions. Volunteer suspects are not police and have no tablet: they get ox_lib notifications, alert and input dialogs and a context menu from the volunteer command only.

- NPCs only: missions MUST involve only NPCs, except live crimes (Config.LiveCrime) and volunteer suspects (Config.Volunteers), both off by default, whose suspects are real players who chose it (a crew whose contract alerted police, or a player who volunteered and said yes). They MUST NOT create SC-Dispatch calls (the one exception is the EMS request sent for a downed participant while EMS is on duty), target real players or spawn anything a non-participant can take.

- Real calls first: when a participant is assigned to, or marks themselves responding to, a real SC-Dispatch call (any call not created by SC-NPCPolice), their run MUST end at once with no penalty and no cooldown. SC-NPCPolice calls MUST NOT end a run. There are exactly three exceptions: un-marking responding within 60 seconds turns the free abandon into a normal one (type cooldown), a call raised about a participant of the same run (their person-down, dead, EMS or panic call) does not end their partners' runs, and in a case with a real suspect, the case's own linked SC-Dispatch call and calls raised by or about its suspects and participants (shots fired, person down, dead, EMS, panic) do not end it.

- No mission alerts: from the moment a participant reaches the mission start until their run ends, their mission combat MUST NOT create SC-Dispatch or SC-Ambulance alerts (shots fired, person down), and any such call that still appears in SC-Dispatch MUST be cleared automatically. A downed participant can still get EMS help. In a case with a real suspect, Config.RealSuspects.officerAlerts decides; shipped: alerts go out like any officer's.

- Route to the start: participants MUST follow the route shown to the mission start; staying off it ends their run as Abandoned. The owner may switch this rule off (Config.Route.required = false): the route is still shown and checked for arrival, but leaving it never ends a run. A run keeps the value it was accepted with, and a test run follows its own Start route switch. Late partners (owner decision): once the run is In progress, a participant still on his way follows the action: his route is no longer checked, his GPS leads to the current objective, and he arrives within Config.Route.lateArriveRange (150 m) of it or at the start (0 = only the start counts), within Config.Route.followActionSeconds (300 s) from then, never less time than he had. In a case with a real suspect, Config.RealSuspects.routeEnds decides; shipped: the route ends at the first contact with a suspect. On a live crime Config.LiveCrime.requireRoute (shipped false) replaces Config.Route.required: officers on a live case may leave the GPS route to chase. Volunteer-suspect missions follow Config.Route.required.

- Downed participants: a participant who goes down has Failed their run. If no EMS is on duty, they MUST be picked up automatically (revived and moved to a drop-off point). In a case with a real suspect, Config.RealSuspects.downed and downedPickupDelay decide; shipped: a downed officer keeps what he earned, no type cooldown, pick-up after 400 s.

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

- Rule switches: no config flag that turns off Hard rules 15, 16 or 18 (real calls, alert suppression, downed participants). Their numbers are configurable; the rules are not. Hard rule 17 (the start route) is the one exception: the owner made it switchable with Config.Route.required (see that rule). In cases with a real suspect, Config.RealSuspects.officerAlerts, routeEnds, downed and downedPickupDelay choose between the rule for real players (shipped) and the NPC rule, and Config.LiveCrime.requireRoute sets the start-route rule for live crimes (shipped false). For NPC missions rules 15, 16 and 18 stay on.

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

Supervisor UI additions: Live Missions gets a Mission calls panel (withdraw, page a unit, create a call); Review Queue gets a Profiles tab (pending pictures, pending bios when bioRequiresApproval is on, and profile reports); Department Report gets arrests, citations, impounds, correct decisions and calls per officer, and "Commend" in each officer's activity.

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

Layout options (presentation only: screen keys, visibility and links never change; the code is in web/src/layouts/, see docs/ARCHITECTURE.md §12)

- Supervisor UI (Config.Tablet, all default false or 'first'): supervisorByTask groups the sidebar by task (people, missions, rewards, review) with a heading over each; supervisorCompact shows icons only; supervisorLanding opens on 'report', 'review' or 'live' when visible (anything else = the first screen) until a screen is picked. supervisorControlsCard shows on Department Report a read-only card of each Mission control he may use now (value in use, whether a change is live, min and max, today's use; the callback is refused with err.controls_card_off while off). supervisorRemember reopens Give points, Mission ban and Clear cooldown with the last successful values (page memory only; out-of-range numbers fall back to the min; the server checks again). supervisorReviewLive pushes a decision on a flagged run or dispute to every other supervisor of the decider's department (an admin without one: every department) with the Review Queue open (asked in the last 75 s); off = at their next 30 s refresh.
- Officer UI (Config.Tablet.sidebarOrder 'classic' or 'mostUsed', activeFirst, compactSidebar): 'mostUsed' lists home, board, active, dispatch, unit, profile, leaderboard, challenge, options; activeFirst moves Active Mission under Home while on a run; compact shows icons only (68 px, names as button titles, badges on the icon).
- Admin UI sidebar: groupSidebar (on) shows Home, Payouts, Missions, Live, Officers and Settings and folds the rest under More (which carries their badge sum; kept open per viewer in the browser). groupByPlay (true) orders the screens by section with headings (NPC missions, Player vs police, Police teamwork, Economy, System), Settings follows the same sections, and Settings → Features lists every feature switch by section with On/Off, a save (risky ones confirm first, money ones need the typed ENABLE) and a link to the setting. plainLayout (false) gives each screen a plain name, a group heading with a one-line description, a screen search (with "Search settings for ...", Enter opens the first) and a breadcrumb over every screen but Home.
- Admin UI pages: rewardsScreen (false) shows the Rewards screen, one place for every payout and item reward of NPC missions, live and volunteer cases and Config.FeatureRewards features, headed by the Rewards.enabled switch, every save a normal setting save. landing ('home'; 'payouts' or 'missions' hide Home) opens on Home: a Live now strip and six tiles (builder, catalog, payouts, officers, settings search, Something wrong? with mission load, config health, problems, payments and today's refusals). homeForms (true) puts quick forms in four tiles (missions and locations on or off, change pay with a reason, give or take points with the typed citizen ID at or above Corrections.adjustConfirmAbove, quick settings) that send the full screens' actions. reasonChips (three texts; at most 8 of up to 60 characters) are buttons under the reason boxes of Set payout, Give or take points and Quick edit that replace the editable reason (Quick edit times are typed in minutes). settingsView ('simple') opens Settings on the everyday settings with plain labels and no Config path; a switch and a button open All settings (by config.lua section); a search or filter looks through every setting; in Simple, MissionTweaks and DisabledLocations point to Missions.
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
- Admin UI → Missions and Testing show each location's play count and last played date. Locations are added to a built-in through a Builder duplicate, and Config.MissionTweaks.disabledLocations switches a built-in spot off (both survive updates).
- The mission is revealed only after accept. No reroll: abandoning, leaving the start route (while Config.Route.required), or missing the start timeout (10 min default) ends the run Abandoned with the type cooldown.

Location lints (tests)

- Zone lint (tests/zone_lint_spec.lua): every start and non-route point of a new mission's locations is at least zoneClearance (250 m for Drug Lab Raid) from every point of every other mission; a route counts by its ends. The 102 existing cross-mission pairs under 200 m are listed in tests/zone_lint_baseline.txt (warnings; the spec fails on a new pair or a longer list); no built-in location moves (that would reset its test status), and the owner checklist offers the list for a clean-up.
- Spawn lint (tests/spawn_lint_spec.lua), on the loaded built-in definitions, flat (2D): (1) no two spawn points of one run closer than 1.5 m (every key a block makes people, vehicles or objects from, as Check spawn points reads them; the escort truck at its route's first point); (2) every list has a point for each person, car or item the largest team brings at once (real CP.Scaling counts, each max applied; hostile_waves: the largest wave on the smallest `use` spawn sets; escort: one per ambush wave), no exceptions; (3) every armed point keeps the start circle plus Config.Builder.spawnMargin (CP.Builder.armedKeepOut) unless the director places it as officers come near (hostile_waves, flee_arrest scatter) or it is staged. Known cases are tests/spawn_lint_baseline.txt (26 lines); the spec fails on an unlisted case, a listed armed key coming closer, a stale line, or a longer list.
- Setup coordinates (`tests/setup_coords_spec.lua`): each shipped mission desk and downed drop-off names its source place in tests/fixtures/foreign_sites.lua on its config.lua line ('from qbx_policejob config/shared.lua:21') and is within 3 m and 1 m of height of it, 1.5 m clear of every other place, inside the map and in no other no-build zone; a desk is 1.5 m or more off its duty point and faces it. The Sandy Shores desk has no Qbox source and is listed as kept.
- Other scripts' places (tests/foreign_sites_spec.lua): no built-in start or spawn point (each block's pointKinds) lies inside the keep-out circle of a fixed place of the public Qbox and ox scripts listed in tests/fixtures/foreign_sites.lua (written by tools/gen_foreign_sites.py from clones of them; README 7.1), flat and within 10 m of height: 6 m round a garage, vehicle spawn or job spot, 4 m round a hospital, station or prison point, 2 m round an ox_target spot (counter, register, safe, locker, stash, door), or the script's own radius when larger, up to 10 m (a bigger area and a wall camera are only listed). No baseline: a conflict is moved.

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

v2 ships 18 missions plus the Weekly Boss, one file each in missions/builtin/. This table is the summary; each mission's full behaviour is in Mission cards.

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

Each card is the full behaviour of one mission. Every card also gets the common bonuses and penalties in Scoring unless it says otherwise, every count marked "scales" is multiplied by the run's tier, and the run's end removes everything the card spawned (NPCs, vehicles, props, target zones, blips; NPC traffic restored). The location lists are in each mission's file.

Locations of a new built-in come from GTA V vehicle nodes and known base-game places and pass the loader's guardrails (no-build zones, 100 m between locations, spawns 30 m from the start) and the cross-mission zone lint (start and non-route points 200 m from every point of every other mission, 250 m for Drug Lab Raid; routes by their ends only; see Random draw rules); a Builder duplicate of each must validate and publish. Each shows "Not tested" in Admin UI → Testing until an admin passes it at the tier its maxOfficers reaches.

Marking terms used below (Config.Markers): anything too far for an officer's game (OneSync streams 424 m) shows where the server has it, so it stays on every map at any distance.
- Checkpoints: the current one is a numbered yellow blip with the block's GPS line (Config.Markers.routeColour) until cleared, the next a smaller numbered yellow blip; an officer still driving to the start or with his own waypoint gets no checkpoint line; under Radio Silence ('area') only the current one shows, without a line, and the HUD names its street.
- The fight circle: a red circle with a skull, "Hostiles", round the fight's spawn points (15 m past the farthest, the boss's spot included), with the GPS line to its centre until you are inside it; each hostile a red dot.
- Chase marking: a runner is an orange blip while he runs and red once he fights or gives up, with the GPS line to the nearest.
- The scene: a yellow map pin "Scene" with the line, until it is processed.

### Beat Patrol · beat_patrol
- Basics: Patrol · 1 officer · ★ · time limit 8 min · cooldown 10 min · quiet patrol (quietPatrol = true: lights and siren after arriving cost −10)
- Locations: 6+ districts, each with 8+ checkpoint spots; a run uses one district and 5 random spots
- Start: the first checkpoint
- Spawns: none; markers and blips only
- Marking: checkpoints (see above)
- Objectives: 1) drive to each checkpoint in order; 2) stop inside its 10 m marker for 10 seconds; a checkpoint counts only from a driver seat (server-checked)

- Fail if: the time limit runs out


### Business Check · business_check
- Basics: Patrol · 1 officer · ★ · time limit 10 min · cooldown 10 min · quiet patrol (quietPatrol = true: lights and siren after arriving cost −10)
- Locations: 12+ businesses; a run uses 4 random ones
- Start: the first business
- Spawns: none; ox_target zones on the front doors
- Marking: each door still to check is a numbered yellow blip, orange while it needs securing, with the GPS line to the nearest. A door's blip stays as it is until that door is done (an update redraws nothing), so the line and its first flash are kept
- Objectives: 1) at each business, ox_target "Check door" on the front door (5 s); 2) the server has rolled each door as secure (75%) or open (25%) and shows the result; an open door adds "Secure door" (5 s); 3) log the result on the tablet: "Secure" or "Found open – secured"

- Fail if: the time limit runs out
- Bonuses: each correctly logged result +5
- Penalties: each wrongly logged result −5

### Street Race Bust · street_race_bust
- Basics: Patrol · 1–2 officers · ★★ · time limit 4 min (the race) · cooldown 15 min
- Locations: 5+ looped race routes of 2–3 km, recorded as road routes (see Route recording)
- Start: an intercept point on the route (waypoint set on accept); the race starts when the first participant arrives
- Spawns: 3 NPC racers in sports cars (scales), racing the route until the time limit ends
- Marking: each racer's car, and a driver out of it, has a red blip with the GPS line to the nearest. A driver who runs on foot is orange until he stops, fights or gives up
- Objectives: 1) stop racers before the race ends; a racer is stopped when its car stays below 5 km/h for 5 seconds; 2) detain each stopped driver with ox_target "Detain driver" (3 s). The run is Completed when every racer is detained, or when the time limit ends with at least one detained
- Scales: racers (base 3)
- Fail if: the time limit ends with no racer detained
- Bonuses: +30 per racer detained, plus +20 more if every racer is detained
- Penalties: ramming a racer at over 100 km/h −10 each; vehiclePenalties = false (boxing racers in means contact)

### EVOC Course · evoc_course
- Basics: Training · 1 officer · ★★ · time limit 4 min · cooldown 10 min
- Locations: 3+ course layouts in open areas such as airfields; each has 12–20 checkpoints and Gold / Silver / Bronze medal times
- Start: the course start marker; the timer starts at the first checkpoint
- Spawns: checkpoint markers only (no cones or props)
- Marking: checkpoints (see above)
- Objectives: drive through every checkpoint in order; a checkpoint counts only from a driver seat (server-checked); a missed checkpoint must be driven through before the next one counts; each wall or vehicle contact adds 2 seconds

- Fail if: the time limit runs out, or the vehicle becomes undriveable
- Bonuses: Gold medal +50, Silver +25, Bronze +10 (replaces the common time bonus); no contact at all +10


### Pursuit Sim · pursuit_sim
- Basics: Training · 1 officer · ★★★ · time limit 5 min · cooldown 15 min
- Locations: 5+ start points, each with a flee route
- Start: the start point; the getaway car spawns 50 m ahead and flees when the officer arrives
- Spawns: 1 getaway car with 1 driver, who flees but never shoots
- Marking: the getaway car, and the driver once out of it, has a red blip with the GPS line to it. A driver who runs on foot is orange until he stops, fights or gives up
- Objectives: stay within 150 m of the car for a total of 3 minutes

- Fail if: the officer is more than 250 m from the car for 10 seconds straight, the officer's vehicle becomes undriveable, or the time limit runs out
- Bonuses: medal by average distance: Gold under 40 m +50, Silver under 80 m +25, Bronze under 150 m +10 (replaces the common time bonus)
- Penalties: ramming the getaway car −10 each (this is a follow exercise)

### Stolen Vehicle Takedown · stolen_vehicle_takedown
- Basics: Training · 1–2 officers · ★★★ · time limit 8 min · cooldown 15 min
- Locations: 5+ last-seen areas, each with a flee route
- Start: an 85 m circle round the last-seen point, 35–42 m from the stolen car (an officer at its edge is 43 m or more from it). When a participant with lights on is within 60 m of the car, it rolls its response: yield (25%), flee (65%) or fight (10%: the passenger is armed and may shoot from the car, drive-by chance 50%)
- Spawns: 1 stolen car with 2 suspects (scales, max 4); after the stop, each suspect has a 20% chance to flee on foot
- Marking: the stolen car, and each suspect once out of it, has a red blip with the GPS line to the nearest (orange while he runs on foot). Once it is stopped each suspect and the car not yet decided keep a blip (a suspect orange while he runs, red once he fights or gives up; the car yellow) until worked
- Objectives: 1) stop the car: it pulls over by itself (yield) or is stopped with a PIT or box-in (below 5 km/h for 5 seconds); 2) aim at each suspect until they surrender (hands up, then kneel); the suspects of a car that yielded stay seated until ordered out; 3) cuff each suspect (Cuff suspect, 5 s), catching any who flee first; 4) Impound the stolen car (10 s progress; the tow truck collects it). Steps 2–4 are a field_contact objective in stop mode that adopts the pursuit's car and suspects (revealed = { 'stolen' }).
- Scales: suspects in the car (base 2, max 4)
- Fail if: a suspect escapes (more than 400 m from every participant for 20 seconds), or the time limit runs out
- Bonuses: car stopped within 2 minutes of the start +15; car impounded +10 (vehicle_impounded; the car's stolen plate is given from the start, so its Impound disposition earns no correct_disposition on top). Each suspect counts as one arrest, whether they were cuffed in the chase or at the contact
- Penalties: ramming at over 100 km/h −10 each; vehiclePenalties = false (PIT stops and box-ins mean contact)

### Warrant Service · warrant_service
- Basics: Investigation · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
- Locations: 5+ houses, each with a front door and a yard
- Start: within 50 m of the house
- Spawns: the suspect inside; 1 armed associate (scales) comes out at the knock, away from the officers (Config.Spawning.associatesAtKnock)
- Marking: before the knock the front door's yellow blip with the GPS line to it; after it the suspect and each associate not yet cuffed, orange while he runs and red once he fights or gives up, with the line to the nearest
- Marking: objective 5 the yard to search, a numbered yellow blip with the GPS line; objective 6 the scene, a yellow map pin "Scene" with the line, until it is processed
- Objectives: 1) ox_target "Knock and announce" on the front door; 2) the suspect's response is rolled: surrenders at the door (50%), flees out the back on foot (30%) or fights with a pistol (20%); associates always fight; 3) cuff the suspect (Cuff suspect, 5 s) unless the suspect was killed while fighting; 4) neutralise every associate (killed, or surrendered and cuffed); 5) ox_target "Search the property" at the yard marker (8 s): the server rolls what is found (60%: narcotics, a weapon, stolen goods or documents), shown on the tablet as virtual evidence; 6) Process the scene (it completes at once when nobody died)
- Scales: armed associates (base 1)
- Fail if: the suspect escapes (more than 400 m from every participant for 20 seconds), every participant is downed, or the time limit runs out
- Bonuses: suspect taken alive +15; no participant downed +10% of P; nobody killed +15 (all_taken_alive)
- Penalties: vehiclePenalties = false (vehicles take gunfire)

### Manhunt · manhunt
- Basics: Investigation · 1–4 officers · ★★ · time limit 12 min · cooldown 20 min
- Locations: 5+ search regions, each with 6+ clue spots and 6+ hiding spots
- Start: entering the 600 m search circle, shown on the map when the type is accepted
- Spawns: 1 fugitive (scales) hidden inside the circle; 3 clue props (a dropped bag, a phone, a witness NPC). They appear as in Suspect behaviour → Manhunt
- Marking: until an officer is inside it, the search circle (yellow; its centre a yellow pin "Search area (600 m)") with the GPS line to its centre, redrawn smaller with each clue. Inside, each clue still to check is a numbered yellow dot and the line goes to the nearest; a fugitive who runs is an orange blip (red once he gives up) with the line on him; with every clue checked and nobody running, the line goes to the shrunk circle again. Under Radio Silence the circle alone shows, without a line
- Objectives: 1) check each clue with ox_target (4 s); each clue shrinks the circle 600 → 300 → 150 → 50 m, always still containing a fugitive; 2) when a participant gets within 30 m, that fugitive runs on foot; 3) catch and cuff every fugitive (Cuff suspect, 5 s). Fugitives are unarmed and give up when stunned, when a participant stays within 3 m of them for 3 seconds, or once worn out by running when a participant is within 30 m (Suspect behaviour, Runners tire)
- Scales: fugitives (base 1)
- Fail if: a fugitive escapes (more than 300 m from every participant for 30 seconds after running), or the time limit runs out
- Bonuses: all 3 clues checked before the first arrest +10; no weapons fired +10
- Penalties: common only (killing an unarmed fugitive fails the mission)

### Gang Shootout · gang_shootout
- Basics: Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min
- Locations: 5+ remote hideouts away from civilian hotspots, each with 12+ hostile spawn points
- Start: within 80 m of the hideout
- Spawns: 20 hostiles (scales) in 3 waves of 7 / 7 / 6, each wave scaled the same way; the next wave spawns when 2 or fewer of the current wave are alive, or after 90 seconds. Pistols and combat pistols; base accuracy 25 and armour 0, plus the tier's increase
- Marking: during the fight the fight circle
- Marking: "Secure the scene" a numbered yellow blip with the GPS line; then the scene (scene pin)
- Objectives: 1) neutralise every hostile (killed, or surrendered and cuffed; a hostile under 25% health has a 30% chance to surrender); 2) ox_target "Secure the scene" at the scene marker (8 s); 3) Process the scene (at most 4 bodies kept)
- Scales: hostiles
- Rules: hostiles use their own relationship group, hostile only to participants; NPC traffic is blocked within 120 m while the run is active
- Fail if: every participant is downed, or the time limit runs out
- Bonuses: no participant downed +10% of P; each hostile arrested +5; nobody killed +15 (all_taken_alive)
- Penalties: vehiclePenalties = false (vehicles take gunfire)

### Hostage Rescue · hostage_rescue
- Basics: Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min
- Locations: 5+ enterable base-game stores or banks (e.g. 24/7 stores, Fleeca banks)
- Start: within 60 m of the building
- Spawns: 4 armed hostiles (scales) inside; 3 hostages kneeling with their hands tied, who appear when objective 2 starts (after the fight), 15 m or more from every officer (Config.Spawning.hostagesAt; 'runStart' = at run start)
- Marking: each hostage still tied is a blue person blip with the GPS line to the nearest; once one is freed the green safe point joins them, so the line leads there when it is nearer. Before the hostages appear the objective's pin is at their first spot. During the fight (objective 1) the fight circle
- Objectives: 1) neutralise every hostile; 2) free each hostage with ox_target "Cut restraints" (6 s); 3) each freed hostage walks to the safe marker outside. Completed when every hostage is there
- Scales: hostiles (hostages stay at 3)
- Fail if: a hostage dies, every participant is downed, or the time limit runs out
- Bonuses: no hostage hurt +15; no participant downed +10% of P
- Penalties: a hostage hit by participant fire −50 each; vehiclePenalties = false (vehicles take gunfire)

### Bomb Disposal · bomb_disposal
- Basics: Tactical · 1–4 officers · ★★ · time limit 6 min (the device timer) · cooldown 20 min
- Locations: 5+ buildings, each with 6+ hiding spots
- Start: within 50 m of the building; the time limit, which is the device timer, starts now
- Marking: while searching, a yellow circle round the hiding spots with a yellow pin "Search area" at its centre and the GPS line to it (never to a hiding spot); then each device still to defuse is a numbered yellow blip named after the mission's target ("Defuse device") with the line to the nearest
- Spawns: 1 device prop (scales), each at a different random hiding spot
- Objectives: 1) search hiding spots with ox_target "Search" (3 s) until every device is found; 2) defuse each device with 4 ox_lib skill checks (easy, medium, medium, hard). All devices share the one timer: a miss takes 30 seconds off it, and 2 misses in a row on one device sets that device off
- Scales: devices (base 1)
- Fail if: the timer reaches 0, or a device goes off. The explosion is an effect only (damage scale 0) and hurts nobody
- Bonuses: no missed skill checks +15; every device found within 2 minutes of the start +10


### Armored Truck Escort · armored_truck_escort
- Basics: Tactical · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
- Locations: 3+ road routes recorded by driving them (see Route recording), each with a depot, a destination and 5+ ambush points
- Start: the depot; the truck leaves when the first participant arrives
- Spawns: an armored truck (stockade) with an NPC driver that follows the route's roads at its set speed (default 60 km/h), keeping to its lanes; 2 ambush waves (scales) of 2 cars each (scales), with 2 armed attackers per car, triggered at random ambush points along the route; the truck and ambush cars appear as in Suspect behaviour → Armored Truck Escort
- Marking: the truck (a blue armoured van blip) and the destination (a yellow flag); each officer's own GPS line goes to the truck while he is more than clearRadius (100 m) from it, else to the destination; the attackers are red dots
- Objectives: 1) escort the truck to the destination; 2) neutralise each ambush wave; 3) the truck reaches the destination with no attacker within 100 m
- Scales: ambush waves and cars per wave
- Fail if: the truck is destroyed, the truck is stopped for 60 seconds straight, every participant is downed, or the time limit runs out
- Bonuses: truck arrives above 50% health +10% of type points; no participant downed +10% of P
- Penalties: vehiclePenalties = false (ramming ambush cars is expected)

### Prison Break · prison_break
- Basics: Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min
- Locations: 5+ breakout points on the outer perimeter of Bolingbroke Penitentiary, each with escape routes and an inmate spawn point of its own for every inmate the largest team brings (8 at 4 officers), 3 m or more apart
- Start: within 150 m of the breakout point
- Spawns: 5 inmates (scales) in prison clothes, already outside the fence and scattering on foot along the escape routes; 2 in every 5 carry pistols and fire when a participant is within 15 m
- Marking: each inmate not yet cuffed: chase marking, so a partner 500 m away still sees him while his escape clock runs
- Objectives: catch every inmate, then cuff them (Cuff suspect, 5 s). An unarmed inmate gives up when a participant aims at them within 10 m, when stunned, or when a participant stays within 3 m for 3 seconds. An armed inmate gives up only when stunned or below 50% health. Any inmate worn out by running gives up when a participant is within 30 m (Suspect behaviour, Runners tire)
- Scales: inmates
- Rules: nothing spawns inside the prison walls, where real players may be jailed
- Fail if: an inmate escapes (more than 600 m from every participant for 30 seconds), or the time limit runs out
- Bonuses: +10 per inmate arrested alive
- Penalties: vehiclePenalties = false (vehicles take gunfire)

### Illegal Parking Patrol · parking_patrol
- Basics: Patrol · 1 officer · ★ · time limit 10 min · cooldown 10 min · quiet patrol
- Locations: 6+ districts, each with 10+ kerb spots; every spot has its posted rule (metered, permit, no parking, hydrant, loading zone or free) and its street name; a run uses 5 random spots of one district
- Start: the district's patrol entry point, 30–60 m before the first spot along the street (radius 85 m: an officer at its edge is 38 m or more from the first spot)
- Spawns: 5 locked, empty NPC cars, one per spot, parked along the kerb. The server rolls each car: legal (45%), a violation (50%: a ticket-level violation on metered and permit spots, a tow-level one on no-parking, hydrant and loading spots; free spots roll legal or stolen only), or stolen (5%). At most one returning driver and one thief (see objectives)
- Marking: every car not yet decided is a yellow car blip with the GPS line to the nearest; a car that has not appeared yet (it appears once an officer is near its spot) shows at its kerb spot as "Parked car to check". A returning driver or a thief is a yellow person blip (orange while he runs)
- Objectives: 1) for each car: Inspect (3 s) shows the posted rule, permit, meter and time parked; Run plate (3 s, beside the car, or as a HUD action from the driver seat of a vehicle within 20 m) shows valid, expired or STOLEN; decide on the tablet or with ox_target: No action (1 s), Write citation (6 s at the windscreen) or Impound (10 s; the tow truck collects it); 2) a returning driver, at most once per run: when the officer cites or impounds a car that isn't stolen there is a 25% chance its driver walks up and either takes the ticket (60%), argues until the officer uses "Explain the citation" (30%, 4 s), or gets in and drives off before the tow is hooked (10%; the citation stands, no penalty); 3) a thief: when an officer first inspects a stolen car there is a 50% chance the thief is nearby and runs on foot once an officer is within 15 m; catch and cuff them (Cuff suspect, 5 s), then hand them to transport

- Fail if: the time limit runs out, or a car whose plate came back STOLEN gets No action or a citation instead of Impound
- Bonuses: each Best decision +5 (correct_disposition with points = 5); all 5 cars Best +10 (all_correct); the thief arrested alive +15 (subject_alive; the thief's own Arrest disposition earns no correct_disposition on top)
- Penalties: citing a legal car −5; impounding a legal car or one that only needed a ticket −15; a violation left without a ticket −5; a stolen car missed because its plate was never run −10; the thief escaping (400 m from the officer for 20 seconds) −15 (missed_arrest; this mission never fails on an escape); lights and siren after arriving at the entry point −10 (quietPatrol)

### Traffic Enforcement · traffic_enforcement
- Basics: Patrol · 1–2 officers · ★★ · time limit 12 min · cooldown 15 min
- Locations: 6+ patrol corridors recorded as road routes of 2–6 km, each with its posted speed and an observation point beside the road. A renamed location keeps its old label in `aliases`, so a location switch saved by the old label still matches. Only the observation point and the corridor's two ends are held to the zone lint (routes of other missions may cross a corridor; the draw's runtime zone clearance keeps two live runs apart)
- Start: the observation point (radius 40 m), at least 30 m from the road spawn point
- Spawns: one violator solo, two with two officers (the second appears once the first stop is closed). Each is 1 car with a driver and passengers (occupants scale: base 1, max 3) that spawns 150–250 m upstream of the observation point and drives past it; the second appears up the road from the officers (Suspect behaviour → Pursuit cars). The server rolls the violation (speeding 20–45 km/h over the posted speed 70%, reckless lane changes 30%), each person's truth (Config.Custody.profileSets.traffic), the car (legal 90%, stolen 10%) and the response to lights (yield 75%, flee 20%, fight 5%; fight only when someone in the car is armed)
- Marking: the HUD announces the violator as it approaches ("Vehicle approaching: 128 km/h" or "Vehicle weaving between lanes"), and the violator car alone gets a blip once it passes the observation point (the second one: once it passes where the officers stood on the road when it set off). Until then the objective blip is the observation point. Ambient traffic is never marked. Once stopped each person and the car not yet decided keep a blip (a person yellow, orange while he runs, red once he draws or gives up; the car yellow) until worked
- Objectives: 1) observe the violation, then stop the car: pace a speeder by staying within 80 m behind it for 5 seconds (the server compares speeds every second and grades the median of the samples, with a 5 km/h tolerance; the HUD shows "Paced: 128 km/h in an 80 zone"), or follow a reckless driver within 60 m for 8 seconds; then light it up within 60 m. A yielding car pulls over with its hazards on; a fleeing car must be stopped (PIT or box-in: below 5 km/h for 5 seconds) and anyone who runs caught and cuffed; the armed occupants of a fighting car must be neutralised; 2) work the stop: Talk to the driver (licence and registration), Run plate, Order out, Frisk, Look inside, Search vehicle (with probable cause), then decide for every person (Warn, Cite, Arrest or Release) and the car (No action or Impound); arrests go to transport; 3) and 4) with two officers, the same for the second violator
- Scales: violators (1 solo, 2 with two officers); occupants per car (base 1, max 3)
- Rules: an observed violation makes the driver at least a Minor offence for grading, so citing a paced speeder is Best. Lighting a car up before observing its violation is a stop without cause: −15 for the officer whose lights started it (stop_without_cause); everything after it is graded normally, and a citation for a violation nobody observed is graded against the driver's own truth. No cones and no checkpoint. Violators never target bystanders. Violator cars are locked for non-participants
- Fail if: a person is released after their warrant or weapon was known to the decider (a knowing error, after the confirm); a car is released or cited after its stolen plate was known to the decider; a suspect escapes (more than 400 m from every participant for 20 seconds); an unarmed or compliant person is killed; every participant is downed; or the time limit runs out
- Bonuses: each Best decision +10 (correct_disposition); procedure complete +10 per officer; no weapons fired +10
- Penalties: the decision penalties in Police actions & decisions; ramming at over 100 km/h −10 each (hard_ram); the heavy vehicle-damage penalty applies

### Suspicious Activity · suspicious_activity
- Basics: Investigation · 1–2 officers · ★★ · time limit 10 min · cooldown 15 min
- Locations: 6+ scenes, each with a car spot, 3+ person spots, 2+ escape paths and a transport point
- Start: a marker 40–60 m from the scene and at least 30 m from every person and car spot, with a 100 m circle (an officer at its edge is 42 m or more from the scene, so it is there before him and nobody reacts until he is within 25 m); the Active Mission screen shows the caller's report, e.g. "A dark sedan has been parked behind the store for an hour"
- Spawns: the server rolls the scene: someone sitting in a parked car (50%), people loitering beside a parked car (30%) or someone looking into parked cars (20%); 1 person (scales, max 3). Each person's truth comes from Config.Custody.profileSets.scene (clean 35, minor 15, warrant 15, narcotics 15, burglary tools 12, armed 8); the car is stolen 15% of the time
- Marking: until the scene appears a yellow pin named after the objective where it will be; then each person (a yellow person blip) and the car (a yellow car blip) not yet decided, with the GPS line to the nearest; a person who runs turns orange, one who draws or gives up red
- Objectives: 1) when the first participant comes within 25 m, each person reacts by demeanour: stays, walks away, runs, or (armed and hostile) shows a tell and draws; 2) make contact: Talk / Check ID, Frisk, Detain, Look inside, Run plate, Search vehicle (with probable cause); 3) decide for every person (Release, Cite or Arrest) and the car (No action or Impound); arrests go to transport
- Scales: people (base 1, max 3)
- Fail if: a person is released after their warrant or weapon was known to the decider (a knowing error, after the confirm); a stolen car is released after its stolen plate was known to the decider; a person escapes (more than 400 m from every participant for 20 seconds); a person who never drew a weapon is killed; every participant is downed; or the time limit runs out
- Bonuses: each Best decision +10; procedure complete +10 per officer; each person who ran or drew and was arrested alive +15 (subject_alive, instead of correct_disposition for that person); no weapons fired +10
- Penalties: the decision penalties in Police actions & decisions; common penalties

### Drug Lab Raid · drug_lab_raid
- Basics: Tactical · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
- Locations: 6+ labs away from civilian hotspots, each with 2 entry points, 14+ hostile spawn points in two spawn sets (inside, yard), 3 cook points (the cooks' hiding spot and 2 on the tracks towards the escape routes, 3 m or more apart: one point for each cook) and 2+ escape routes, 6+ stash spots, the lab point and a scene marker
- Start: within 80 m of the lab
- Spawns: 9 hostiles (scales) in 2 waves of 5 / 4, holding cover inside (tactics rolled: hold 50%, balanced 40%, push 10%); pistols, combat pistols and pump shotguns; base accuracy 25 and armour 0 plus the tier's increase; a hostile under 25% health has a 30% chance to surrender. 1 unarmed cook (scales, max 3). 2 stashes (scales, max 4) hidden among the stash spots
- Marking: during the fight (objective 2) the fight circle
- Marking: during the cook chase each cook not yet cuffed: chase marking
- Marking: the two entry points to breach are numbered yellow blips with the GPS line to the nearest; the stash search a yellow circle with a yellow pin at its centre and the line to it (never to a stash); the lab to shut down a numbered yellow blip "Shut down the lab" with the line, orange, flashing and named "Ventilate 1" while it is set back until it is ventilated (Config.Markers.setbackFlash); the scene (scene pin)
- Objectives: 1) breach: ox_target "Stack up and breach" (3 s) on both entry points, by 2 different officers within 6 seconds of each other (the count is min(2, participants still in the run): when only one is left, one officer breaches both entries with an 8 s progress each, so the run never soft-locks); 2) neutralise every hostile (killed, or surrendered and cuffed); 3) when the last hostile falls the cooks bolt along an escape route: catch and cuff them (unarmed; they give up when aimed at within 10 m, when stunned, when a participant stays within 3 m for 3 seconds, or once worn out by running when a participant is within 30 m); 4) search the stash spots ("Search", 4 s progress) until every stash is found, then "Seize the product" (6 s); 5) "Shut down the lab" at the lab point: 3 ox_lib skill checks (medium, medium, hard); 2 misses in a row start a toxic fire (an effect only, it hurts nobody), a setback and never a fail: any participant must "Ventilate" (10 s) at the lab point, the officer who missed loses 15 points (lab_fire, personal), and the shutdown can be tried again 30 seconds later by anyone; 6) Process the scene
- Scales: hostiles, cooks (max 3), stashes (max 4)
- Rules: hostiles use their own relationship group, hostile only to participants; NPC traffic is blocked within 120 m while the run is active; the seized product is virtual evidence (no items, but it counts as an evidence find for item rewards)
- Fail if: a cook escapes (more than 400 m from every participant for 20 seconds), an unarmed cook is killed, every participant is downed, or the time limit runs out
- Bonuses: no participant downed +10% of P; each hostile arrested +5; each cook arrested +10 (cook_arrested); every stash found within 3 minutes of the breach +10 (stash_found_fast); nobody killed +15 (all_taken_alive)
- Penalties: a toxic fire −15 for the officer whose checks missed (lab_fire); common penalties, except vehiclePenalties = false (vehicles take gunfire)

### Gang Hideout Raid · gang_hideout_raid
- Basics: Tactical · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
- Locations: 6+ urban hideouts, each with 2 entry points, three spawn sets of 6+ spawn points each (front, house, garage or back yard), a lieutenant spot, 4 runner points (on the lanes from the back of the house to the escape routes, 3 m or more apart and never on the lieutenant's spot: one point for each runner), 2+ escape routes, 6+ cache spots and a scene marker
- Start: within 100 m of the hideout
- Spawns: 16 hostiles (scales) in 3 waves of 6 / 5 / 5 from 2 of the 3 spawn sets, rolled per run (the Active Mission screen shows the intel line, e.g. "Intel: expect contact in the garage and the house"); tactics rolled (hold 30%, balanced 50%, push 20%); pistols, combat pistols and pump shotguns; base accuracy 28 and armour 10 plus the tier's increase; 30% surrender under 25% health. After the last wave, the lieutenant: health 300, armour 50, a heavy pistol, 50% surrender under 25% health; does not scale. 2 unarmed runners (scales, max 4). 1 weapons cache (scales, max 2) hidden among the cache spots
- Marking: during the fight (objective 2) the fight circle, the lieutenant a bigger one named "The lieutenant"
- Marking: during the runners' chase each runner not yet cuffed: chase marking
- Marking: the two entry points to breach are numbered yellow blips with the GPS line to the nearest; the cache search a yellow circle with a yellow pin at its centre and the line to it (never to a cache); the scene (scene pin)
- Objectives: 1) breach together on both entry points (as Drug Lab Raid); 2) neutralise every hostile, then the lieutenant; 3) when the lieutenant falls the runners bolt: catch and cuff them; 4) search the cache spots until every cache is found, then "Seize the weapons" (6 s); 5) Process the scene
- Scales: hostiles, runners (max 4), caches (max 2)
- Rules: hostiles hostile only to participants; NPC traffic blocked within 120 m; nothing is looted
- Fail if: a runner escapes, an unarmed runner is killed, every participant is downed, or the time limit runs out
- Bonuses: lieutenant arrested alive +25 (lieutenant_alive); each hostile arrested +5; no participant downed +10% of P; every cache found within 2 minutes of the breach +10 (stash_found_fast); nobody killed +15 (all_taken_alive)
- Penalties: common only, except the heavy vehicle-damage penalty, which is off (vehiclePenalties = false)

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
- LIVE calls (Config.LiveCrime, off) mirror a real SC-Dispatch crime with real-player suspects: claiming opens the live case at its reported place, with no draw, twists or rapid response, and is never re-dispatched. Its claim, ready check, cooldown and anti-farm rules (Config.LiveCrime, Config.RealSuspects), backup joining, the officers' Live case card and result outcomes, and the staff Real suspects screen with its tools (block pair, exclude, suspend, lift, clear strikes) are in docs/ARCHITECTURE.md §5.45–5.47 and README 9.16. A staff member who was a suspect of a case counts as taking part in its run: he never reviews or reads it.

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
- The van and tow truck show on every run officer's map (Config.Markers.serviceVehicles: "Prisoner transport", "Tow truck", blue) from appearing to leaving, in every Radio Silence mode, never with a GPS line; sent when their status changes, followed once near enough; late partners get them too. The coroner van is unmarked.

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

Achievement badges: Iron Wheels (20 completed runs with no vehicle damage), Sharpshooter (10 Gang Shootouts with no participant downed), Road Warrior (100 Patrol missions), Partner in Crime (50 unit runs), Joint Task Force (10 runs with 2 or more departments), By the Book (100 Best dispositions) and First Responder (25 mission calls with rapid response). The counts are in Config.Badges.

Daily and weekly goals: each officer gets one daily goal (picked at the daily reset, Config.Time.resetHour) and one weekly goal (picked on Monday) from Config.Goals, e.g. "Complete 2 Patrol missions" or "Complete 1 cross-department run". Progress is counted from the officer's runs since the goal was picked. Goals are picked with a random seed made from the date (or the week's start) and the officer's citizenid, so a restart keeps the same goals and nothing needs storing. Finishing one adds +50 (daily) or +200 (weekly) points once, as a 'goal' row. Goals may also count mission calls or a stat (arrests, citations, impounds, rescues, vehicles stopped, evidence, correct decisions) from completed rows only (the kinds in Config.Goals). A department's supervisor may narrow the lists his department's officers draw from to some of the admin's goals (the goals Mission control, shipped off): the pick counts from the next weekly reset, the points stay Config.Goals.dailyPoints / weeklyPoints, and the setter keeps the whole lists.

## XP levels & service record

Points, XP and levels are three views of one number.

| Name | What it is | Where it shows |
|---|---|---|
| Points | What one run earned; ranks the Weekly, Monthly and Season boards | Result screen, boards, history |
| XP | Every point an officer has ever earned (counted runs, goal rows, manual awards); never resets | The XP bar |
| XP level | A number worked out from XP (Lv 1–50, then prestige stars); its band gives the XP level name | The number in the header, boards and unit lists; number and name on Home and the profile |

- The result screen shows "+142 points" once, and under the level bar "+142 XP · 312 XP to Lv 24". Points go to the boards of their period; XP stays for good.

- Level curve (Config.XPCurve): level 1 starts at 0 XP; reaching level n needs round(100 × (1.07^(n−1) − 1) ÷ 0.07) XP, so each level needs 7% more than the one before. Level 10 ≈ 1,200 XP, 25 ≈ 5,800, 38 ≈ 16,000, 50 ≈ 37,900. After level 50, every 10,000 XP adds a prestige star (Lv 50 ★2).

- One ladder: the XP level names and badge colours still come from Config.XPLevels, and each name is now a band of numbered levels (Config.XPLevels[n].level: Probationary Lv 1–9, Patrol Officer Lv 10–24, Senior Patrol Lv 25–37, Veteran Lv 38–49, Elite Lv 50 and prestige). The xp thresholds in the file stay close to each band's first level. The header shows only "Lv 23" next to the Qbox rank; Home and the profile show "Lv 23 · Senior Patrol".

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

Rank by: Points (default) · Missions · Arrests · Impounds · Citations · Rescues · Mission calls · Judgement. The All-time tab keeps ranking by XP and shows each officer's level. Live catches (suspects detained in live cases, Config.LiveCrime) is one more tab the owner can add to Config.Leaderboard.metrics (not on the shipped list).

- Missions counts completed runs; Mission calls counts completed runs claimed from a call; Arrests, Impounds, Citations and Rescues sum those columns over completed rows only (`WHERE state = 'completed'` plus the void and flag rules); Judgement ranks Best dispositions (decisions_best) as a share of all dispositions (decisions_ok + decisions_bad), and needs at least 10 decisions in the window (Config.Leaderboard.minDecisions), with more decisions winning a tie.

- Every metric uses the same period, filter, 3-run minimum, privacy toggle, void and flag rules, pinned own row and 60-second cache as points. Ties go to more points, then fewer failed runs, then whoever reached the score first.

- Every row shows the officer's level badge and avatar. Cash and kills are never shown.

- Optional weekly badges per metric (Config.Leaderboard.weeklyBadges, e.g. { 'arrests' } gives "Top Arrests of the Week"); Officer of the Week stays by points.

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
| Weekly bounty | Each Monday the server picks one objective at random from Config.Challenge.bounties (e.g. "Most Tactical missions", "Most cross-department runs", "Most arrests", "Most mission calls"), and an admin can override it for that week. The department with the highest count per active officer wins a bonus of 10% of the challenge points its officers earned that week, added once when the week closes |
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

Commendations (Config.Commendations)

- Supervisors (Department Report → activity) and admins (Admin UI → Officers) Commend: a kind (Valor, Lifesaving, Teamwork, Professionalism, Leadership, Investigation), a citation of 10–255 characters, optionally the run. A supervisor: own department only (crossDepartment = false), never himself or for a run he was on, 3 a day, not the same officer and kind within 7 days; admins anyone.
- No points or cash, never counted toward goals, badges, bounties or boards. The recipient gets a toast and a Home announcement for 7 days; with announce the board webhook posts it. The issuer or an admin revokes with a reason; all audited. Config.Profile.showMdtCommendations (off) shows SC-Dispatch MDT commendations read-only, tagged "MDT".

Field training (Config.FieldTraining, off)

- A supervisor (Department Report → Field training → Pair trainer) or admin pairs a rookie with an online trainer of the same department at Qbox grade trainerGrades.<department> or more (else supervisorGrade); never his own character as the rookie; one trainer per rookie, at most rookiesPerTrainer per trainer, who is not in training himself. End training (two clicks) unpairs.
- A completed, unflagged run counts for the rookie when his trainer finished the same run: one towards the task of its type (tasks, a count per type), up to the count; test runs never. At the count the trainer is told and signs it off (Profile → Field training, optional note up to 255 characters), once per task, only his own rookie's. All signed off = done, with the badge Config.FieldTraining.badge (also in the admin Grant / Revoke list while on).
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
- Block settings → each block's panel shows every value with its minimum, maximum and default and refuses anything outside; the ranges and defaults are config/blocks.lua (its copy is under Config). With Config.Builder.foldAdvanced (shipped true) a panel shows the objective name and the basics (hostile_waves: Waves, Enemies per wave, Weapons, Difficulty Easy/Normal/Hard, which set accuracy, armour and health inside their ranges) and folds the rest, with the minimum time ("Flag runs finished faster than") and presence range ("Officers must stay within", 50–800 m), under "More settings"; Details folds all but name, type, difficulty and team size. An error opens the fold.
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

All storage is in cp_ tables. The exact columns are the migration files in Crimson-Police/sql/migrations/ (001_initial.sql is the fresh schema; 002–017 only add) and the column meanings are in docs/ARCHITECTURE.md §3–§5. Leaderboards are computed from cp_mission_runs, one row per participant per run, so every point and payment traces back to the run that earned it.

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
| cp_pvp_pairs | The anti-farm pair ledger (009): one row per officer and suspect of a closed live or volunteer case, an admin's block, exclusion or suspension, a duty-off time, and volunteer strikes and strike blocks (vol_strike, vol_block while Config.Volunteers.saveStrikes is on); empty until such a thing happens; case and duty rows kept for Config.RealSuspects.pairLedgerDays |
| cp_dept_controls | One department (or '*' server-wide) and Mission control a supervisor or admin changed (011); no row = the config value; a row past expires_at is ignored, also after a restore |
| cp_pvp_cases | One closed live or volunteer case as the Real suspects screen reads it, never a position (016); only the newest Config.RealSuspects.casesKept, none older than pairLedgerDays, while Config.RealSuspects.saveCases is on |

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

The folder layout, the feature folders, the module APIs and every net event, callback and action are in docs/ARCHITECTURE.md (§1 folders and load order, §5 modules, §7 blocks, §8 events, callbacks and actions). The rules that shape the whole resource:

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
| GetAvailablePolice() | Server | Read-only: the on-duty officers who could answer a crime (Config.LiveCrime.availablePolice) and a count per department; nil while Config.LiveCrime.enabled is false |
| OpenTablet() | Client | Opens the Officer UI with the same checks as /CrimsonPolice |

Server-only events (other scripts listen with AddEventHandler; no server id or position in either): crimson-police:server:liveCrimeEnded when a live case ends (Config.LiveCrime.endEvent: the reporting script's crime names, how the run ended, each suspect's outcome by citizenid, the counts of suspects caught and officers), and crimson-police:server:volunteerEnded when a volunteer's mission ends (Config.Volunteers.endEvent: his citizenid, the mission id and type, his role, the mode, his outcome, why his part was voided, whether officers reached him, how the run ended, the officer count).

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
- Lists of tables have row editors with the same checks as the raw editor: Builder.noBuildZones (label, centre, radius 10-500 m; the two Crimson-Arena zones may grow but never move, shrink or go), Downed.dropOffs (1-10 points), MissionCalls.areas (unique keys, centres inside the map), Scaling (1-10 rows, maxParticipants rising, the last covering Limits.maxUnitSize, known tiers), XPLevels (the first at 0 XP and level 1, both rising, the shipped badge colours) and Profile.avatarPresets (the pictures the UI ships).
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

-- Every Crimson-Police setting. If this file and the spec disagree, this file wins.
-- You never have to edit this file: an admin can change every setting in game (Admin UI → Settings). A change made
-- there is saved over the value here and survives restarts; Reset puts this file's value back.

-- CONTENTS: six parts, laid out like the Admin UI. Each block below has a banner with its name, which is also its
-- section in Admin UI -> Settings -> All settings. Every key has a comment with its unit and the values it takes;
-- in a list of entries that all have the same fields (Bonuses, map markers, departments), a line "field: text"
-- above the list explains that field for every entry.
--   PART 1 GENERAL              Debug, Storage (database or saves folder), Formats, Tablet and commands, Permissions,
--                               Admin control, Departments, Names
--   PART 2 NPC MISSIONS         Mission types, Difficulty, Scaling by participants, Spawning, Suspect behaviour,
--                               Route to the start, Map markers, Random draw, Dispatch (mission calls), Real calls,
--                               Alert suppression, Downed participants, Police actions and custody, Decisions,
--                               Special events, Built-in mission tweaks, Mission Builder
--   PART 3 PLAYER VS POLICE     Real suspects, Live crimes, Volunteer suspects, Criminal tablet
--   PART 4 POLICE TEAMWORK      Units, Cross-department missions, Mission controls, Field training, Leaderboard,
--                               Department challenge, Officer profile (and My options, commendations)
--   PART 5 ECONOMY AND REWARDS  Cash, Payout editing, Disputes, Scoring, XP levels and goals, Bonuses and penalties,
--                               Item rewards, Feature rewards
--   PART 6 SYSTEM               Run limits, Anti-exploit, Time, Admin test mode, Retention, Backups (webhooks are
--                               server.cfg convars, listed at the end)
-- Mission Builder ranges (what a builder may pick for each block) are in config/blocks.lua.

Config = {}

-- ############################################################################
--                               PART 1 · GENERAL
-- Debug lines, the language, where data is saved, the tablet and its commands, the admins and the
-- Admin UI, what supervisors and admins may do, the departments and the names admins give.
-- Usually changed here: Database (before the first start), the tablet keys and desks, and your departments' jobs
-- and supervisor grades.
-- ############################################################################

Config.Debug = true              -- true = each module prints tagged debug lines
Config.Locale = 'en'             -- the language of every text: 'en' (English) only

-- ============================================================================
--                                   STORAGE
-- ============================================================================
-- enabled = true:  keep everything in your MySQL/MariaDB database through oxmysql. The tables are
--                  created automatically on start; there is no SQL file to import.
-- enabled = false: database off. Everything is saved as files in the resource's saves folder
--                  (Crimson-Police/saves). Keep that folder when you update the resource, and back it up.
-- Changing this moves no data: Crimson-Police starts with what the other storage holds (nothing, the
-- first time). To take your data along, use /CrimsonPoliceAdmin storage copy (see the README).
-- folder only matters when enabled = false: a folder inside the Crimson-Police folder (FXServer only lets
-- a resource write inside resource folders). A full path works when it points inside the resource.
Config.Database = {
    enabled = false,  -- true = MySQL/MariaDB through oxmysql; false = files in the saves folder
    folder = 'saves', -- files mode: the folder inside Crimson-Police the files are saved in
    -- Files mode: after this many milliseconds of saving, Crimson-Police lets the server run its other work for a
    -- moment before the next save (what oxmysql does in database mode); 0 = never pause (the old timing)
    saveTurnMs = 4,
    -- Files mode: how many answers of JSON lookups (badge counts read every run of an officer) are kept; about 50 bytes
    -- each, 100000 = about 5 MB; 20000 = the old size; 0 = keep none
    jsonCacheEntries = 100000,
}

-- ============================================================================
--                                   FORMATS
-- ============================================================================

Config.Format = {
    currency = '$',              -- money symbol
    currencyAfter = false,       -- true = the symbol goes after the amount (250 $)
}

-- ============================================================================
--                             TABLET AND COMMANDS
-- ============================================================================

Config.Tablet = {
    title = 'Crimson-Police',            -- app title on every screen
    command = 'CrimsonPolice',           -- opens the Officer UI
    adminCommand = 'CrimsonPoliceAdmin', -- opens the Admin UI; also takes subcommands
    keybind = '',                        -- default key ('' = none; players can bind it in GTA settings)
    dispatchKey = '',                    -- default key that opens the tablet on Dispatch ('' = none)
    readyKey = '',                       -- default key that answers a unit ready check with Ready ('' = none)
    -- default key for contact HUD actions: run plate from a vehicle, place in vehicle, hand over, escort
    contactKey = '',
    item = false,                        -- ox_inventory item name that also opens the tablet, or false
    prop = 'prop_cs_tablet',             -- prop held while the Officer UI is open
    access = {                           -- which ways open the Officer UI; the server refuses a way that is off
        command = true,                  -- /CrimsonPolice
        keybind = true,                  -- the crimsonpolice_tablet key mapping
        item = true,                     -- using Config.Tablet.item (only when item is set)
        desk = true,                     -- the mission desks below
        -- true = every way except a desk needs the item in the inventory; accepting a mission and claiming a mission
        -- call check it again (away from the desk the tablet was opened at, the item is needed then too)
        requireItem = false,
    },
    deskDistance = 3.0,                  -- metres: walking further than this from the desk closes the tablet
    deskScenario = 'PROP_HUMAN_ATM',     -- standing-and-typing animation at a desk (no handheld tablet)
    -- Milliseconds (0-1000) the GTA pause key is blocked after Escape or the close button closes the tablet, so the
    -- same Escape press does not also open the pause menu (0 = off)
    pauseGuardMs = 300,
    -- The Officer UI sidebar order: 'classic' = Home, Mission Board, Dispatch, Unit, Active Mission, Leaderboard,
    -- Challenge, Profile, My options (as before); 'mostUsed' = Home, Mission Board, Active Mission, Dispatch, Unit,
    -- Profile, Leaderboard, Challenge, My options. Only the order changes
    sidebarOrder = 'classic',
    -- true = while the officer is on a run, Active Mission moves to the top of the sidebar, right under Home; false =
    -- it keeps its place (as before)
    activeFirst = false,
    -- true = the Officer UI sidebar shows only the icons (the name shows on hover), leaving the screens more room;
    -- false = icons and names (as before)
    compactSidebar = false,
    -- true = the Supervisor UI sidebar is grouped by task under four headings: People (Department Report: officers,
    -- give points, mission bans, field training), Missions (list, live, cross-department, controls, builder),
    -- Rewards (payouts) and Review (the review queue); false = one list (as before). Only the layout changes
    supervisorByTask = false,
    -- true = the Supervisor UI sidebar shows only the icons (the name shows on hover); false = icons and names
    -- (as before)
    supervisorCompact = false,
    -- The screen the Supervisor UI opens on: 'first' = the first one it shows (as before), 'report' = Department
    -- Report, 'review' = Review Queue, 'live' = Live Missions (a screen the supervisor may not see = the first one)
    supervisorLanding = 'first',
    -- true = Department Report shows a 'Your controls today' card: each Mission control the supervisor may use now,
    -- its current value, the admin's limits (min and max) and today's use against the per-day count; false = no
    -- card (as before). Only shows what the server already checks
    supervisorControlsCard = false,
    -- true = the supervisor dialogs Give points, Mission ban and Clear cooldown open with the points, hours and reason
    -- last used on this tablet (kept until Crimson-Police restarts or the player reconnects), so a second award or ban
    -- in a row needs no typing; false = they open empty (as before). The server checks every value again
    supervisorRemember = false,
    -- true = when a supervisor or an admin decides a flagged run or a dispute, the other supervisors of that
    -- department who have the Review Queue open see the updated queue at once; false = they see it at their next
    -- refresh, within 30 seconds (as before)
    supervisorReviewLive = false,
    -- Mission desks: ox_target boxes that open the Officer UI, one per police station the Qbox police script
    -- knows, each 1.5-3 m from its duty point in the base-game interior and facing it. A custom station MLO may need
    -- a desk moved: Admin UI -> Departments -> Desks. departments = nil lets every department use a desk;
    -- prop = a laptop only that player sees, or false. tests/setup_coords_spec.lua checks the source of each 'from'
    desks = {
        {
            label = 'Mission Row PD front desk',
            coords = vec3(441.00, -977.30, 30.69),     -- from qbx_policejob config/shared.lua:21 (the duty point)
            size = vec3(1.2, 0.8, 1.0),
            rotation = 21.0,
            departments = nil,
            prop = false,
        },
        {
            label = 'Sandy Shores office',
            coords = vec3(1853.20, 3689.60, 34.27),    -- kept: Qbox gives this station a map blip, no duty point
            size = vec3(1.2, 0.8, 1.0),
            rotation = 30.0,
            departments = nil,
            prop = 'prop_laptop_01a',
        },
        {
            label = 'Paleto Bay sheriff front desk',
            coords = vec3(-448.55, 6011.92, 31.82),    -- from qbx_policejob config/shared.lua:22 (the duty point)
            size = vec3(1.2, 0.8, 1.0),
            rotation = 52.0,
            departments = nil,
            prop = false,
        },
    },
}

Config.AdminAce = 'crimsonpolice.admin'     -- the admin permission; supervisors come from job grade
Config.QboxAdmins = true                    -- true = your Qbox admins (group.admin, which holds the 'admin'
                                            -- permission) are Crimson-Police admins too; false = only AdminAce
Config.AdminTheme = {          -- Admin UI colours (hex)
    primary = '#a4161a',       -- buttons and highlights
    accent = '#e5383b',        -- links and secondary highlights
    background = '#0b090a',    -- the page behind the panels
    surface = '#161a1d',       -- panels and cards
    text = '#f5f3f4',          -- body text
}
Config.AdminUi = {
    -- true = the Admin UI sidebar shows the everyday screens (Home, Payouts, Missions, Live, Officers, Settings) and
    -- folds the rest under More, whose badge adds up theirs; false = every screen in one flat list
    groupSidebar = true,
    -- true = the Admin UI sidebar and Settings put screens and settings under three plain sections, NPC missions,
    -- Player vs police (real players as suspects) and Police teamwork (cop and cop), with money and the server
    -- after them; false = the sidebar order and the Settings groups as before. Only the layout changes
    groupByPlay = true,
    -- The screen the Admin UI opens on: 'home' = a landing screen with the common jobs (new mission, missions on or
    -- off, pay, points, quick settings, what is wrong) and the live runs; 'payouts' or 'missions' = open straight
    -- on that screen, with no Home screen
    landing = 'home',
    -- The view Admin UI -> Settings opens in: 'simple' = only the everyday settings in plain groups, with plain
    -- labels and help texts ('All settings' is one click away); 'all' = every setting by config.lua section
    settingsView = 'simple',
    -- true = the Home tiles hold the quick forms (switch missions and locations on or off, change pay, give or take
    -- points, the everyday settings), each done right there; false = the tiles only open the full screen
    homeForms = true,
    -- Ready-made reasons shown as buttons under the reason box when setting pay, giving or taking points and in a
    -- mission's Quick edit: a click fills the box, which can still be typed in; {} = no buttons, only typing
    reasonChips = { 'Balance change', 'Event', 'Correction' },
    -- true = the Admin UI uses plain names and puts every screen under seven groups, each with a one-line
    -- description: NPC missions, Player vs police, Police teamwork, Rewards, Permissions, Economy and System; the
    -- rarely used tools fold under More, a search box finds any screen or setting, a breadcrumb shows where you are
    -- and each screen's title uses the same plain name; false = the sidebar and titles as before. Only the layout
    -- changes
    plainLayout = false,
    -- true = the Admin UI gets a Rewards screen: every feature that pays (NPC mission types, live and volunteer
    -- cases for officers, volunteer suspects, talk-downs, field training, supervisor awards) on one page, each with
    -- its money, how it is paid and its items, saved like any setting; false = no such screen (Settings still has
    -- every value). Nothing is paid differently
    rewardsScreen = false,
    -- true = Admin UI -> Home shows a "Needs attention" panel on top: the Problems lines, today's refused mission
    -- starts, the open disputes, the flagged runs waiting for a review and the open player suspect cases, each a
    -- count that opens its screen; false = no such panel (Home as before). It only reads
    needsAttention = false,
    -- true = Mission pay and Payments made become one Money screen with two tabs; old links, Home tiles and a
    -- landing of 'payouts' open the right tab; false = two separate screens as before
    moneyScreen = false,
    -- Rows per page (10-200, e.g. 50) on the long Admin UI lists, each read a page at a time from the server:
    -- Activity log, Payments made, Officers, an officer's runs on Leaderboards and the Player suspects cases;
    -- 0 = each list as before (Activity log 50, Payments made 25, Officers 25, the last 100 runs, every case)
    pageSize = 0,
    -- true = Payments made and Leaderboards each open with one request to the server (the totals and the flagged
    -- runs come with the list) instead of two; false = two requests as before. The screens show the same
    oneRequest = false,
    -- true = the long lists of every tablet UI (a scrolling table of more than 100 rows, such as the Admin UI's
    -- Leaderboards board, the officer Leaderboard and the supervisor Department Report, and the Settings search
    -- results) draw only the rows in view and add the next ones as you scroll, so a big list opens and scrolls
    -- faster; false = every row is drawn at once as before. The rows and their order are the same
    windowRows = false,
    -- true = the settings-heavy Admin UI dialogs (a department, a mission desk, Void runs) and the Supervisor UI's
    -- Mission controls show the options changed every day and fold the rarely changed ones under a More button;
    -- each screen remembers on that computer whether More was left open (the Mission Builder's "More settings" of
    -- a block too), and a control that is set never hides; false = every option shown open, as before. Only the
    -- layout changes
    foldAdvanced = false,
}

-- ============================================================================
--                                 PERMISSIONS
-- ============================================================================
-- What supervisors may do. Admins can always do every admin action.
-- false hides the action in the Supervisor UI, and the server refuses it.
Config.Permissions = {
    supervisor = {
        setTypePayout = true,     -- within Config.Payouts limits; never a type an admin has set
        launchCrossDept = true,   -- launch, start now, relaunch and cancel; also remove a joiner before the start
        forceRecall = true,       -- end one officer's run with no penalty (their department's runs only)
        reviewFlagged = true,     -- approve or void flagged runs involving their department
        handleDisputes = true,    -- disputes about flagged or voided runs in their department
        builderEdit = true,       -- create, edit, record routes and test their own missions
        builderPublish = true,    -- publish their own drafts (testing is optional, see Config.Builder)
        builderArchive = true,    -- archive or restore their own missions
        builderEditAny = false,   -- also edit, publish and archive other people's custom missions
        builderRollback = false,  -- roll a custom mission back to its previous version
        breakEditLock = false,    -- unlock a mission someone else is editing
        missionCalls = true,      -- view, withdraw, page and create mission calls
        issueCommendation = true, -- commend officers of their own department
        reviewProfiles = true,    -- approve or reject pictures and clear bios of their department
        -- change the Mission controls an admin switched on, for their own department only (Config.MissionControls)
        missionControls = false,
    },
    -- Who besides admins may use the Mission Builder Teleport button (admins always may), by department key: minGrade
    -- (that grade or higher) or grades (only those grades). For example sast = { minGrade = 4 } or
    -- the list form bcso = { grades = { 3, 5 } }. Empty = admins only.
    builderTeleport = {},
    -- Extra grants (Admin UI -> Permissions -> Extra grants): a power for people who are not supervisors, by power key
    -- (a key of supervisor above, builderTeleport, fieldTraining = pair and unpair field training, or criminalTablet,
    -- the criminal tablet while Config.CriminalTablet.access is 'granted'). Each power may name departments from a
    -- grade, e.g. departments = { sast = { minGrade = 3 } } (or { grades = { 3, 5 } }), Qbox gangs the same way,
    -- e.g. gangs = { ballas = { minGrade = 2 } }, and single characters by their citizenid, e.g. the list
    -- of citizenids = { 'ABC12345' }. A power switched off above stays off for everyone, an admin-only action can
    -- never be granted and admins still come only from AdminAce and QboxAdmins. Empty = only supervisors (and the
    -- builderTeleport grades), as before
    grants = {},
    -- Always admin-only, whatever is set above: single-mission payouts, clearing
    -- admin payouts, manual awards (apart from the awardPoints Mission control), disputes
    -- about failed runs, voiding any run, seasons, the bounty override, suspensions, reloading
    -- mission files and test runs.
    -- Nobody may approve, void or answer a dispute about a run they took part in.
}

-- ============================================================================
--                                ADMIN CONTROL
-- ============================================================================
-- What admins may do beyond the normal rules, from the Admin UI. Supervisors never get these. Every action is in
-- the audit log; limits are counted from saved rows, so a restart never resets them.
Config.AdminControl = {
    pointAdjust = true,          -- Officers → Give or take points: logged manual awards and deductions
    adjustConfirmAbove = 500,    -- points: a typed confirmation at or above this
    adjustDailyLimit = 0,        -- points one admin may adjust per day (0 = no limit)
    editBuiltins = true,         -- Mission Builder: admins edit built-in missions (saved as an override, same id)
    recordMove = true,           -- Officers → Move record: a re-created character's history to the new citizenid
    bulkMaxRows = 5000,          -- rows one bulk void or restore may change
    cooldownClearsPerDay = 3,    -- cooldown clears per officer per day
    extraRunsMax = 10,           -- extra completions per officer per day
    streakForgiveMax = 7,        -- streak days one forgive may cover
    runTimeAddMax = 600,         -- seconds an admin may add to one live run
    -- Departments → Upload a logo: milliseconds between two 16 KB pieces of the picture. 250 keeps the upload at half
    -- of what FXServer lets one player send per second (it drops a player who sends more); 1 MB then takes about 22 s.
    logoChunkGapMs = 250,
    -- Milliseconds between progress updates of a running bulk job on admins' screens (the start and the end of a job
    -- are always shown at once); 0 = after every batch (the old behaviour).
    jobProgressEveryMs = 500,
    -- Refused mission starts the server remembers for admins (who tried, which mission, why), newest kept. Memory
    -- only: a restart empties the list.
    refusalsKept = 200,
}

-- ============================================================================
--                                 DEPARTMENTS
-- ============================================================================
-- Every entry is used automatically for access, the tablet name, colours and
-- logo watermark, leaderboards, the department challenge, unit invites and the
-- Mission Builder. Add a block, put its logo in logos/, restart. No code or SQL changes.
-- Usually changed here: jobs and supervisorGrade (they decide who uses the tablet and who supervises). Each has:
-- label: the full name, shown in the tablet header
-- enabled: false = turned off: nobody new joins, history and pay stay
-- short: the tag on boards, units and badges
-- jobs: the Qbox job names of this department (as in sc-police / sc-dispatch)
-- supervisorGrade: Qbox grade number: this grade and up are supervisors
-- societyAccount: its Renewed-Banking account, only used when Config.Cash.source = 'society'
-- primary: tablet colour (hex) of the header, buttons, active tab and progress bars
-- accent: tablet colour (hex) of highlights, badges and focus outlines
-- background: tablet colour (hex) of the body
-- surface: tablet colour (hex) of cards, tables and dialogs
-- text: tablet text colour (hex); optional, picked automatically for contrast when left out
-- file: the logo's file in logos/ (or use url)
-- url: an https:// link to the logo instead of a file (optional)
-- watermark: true = draw the logo behind every screen
-- opacity: how solid the watermark is, 0.0 to 0.25
-- size: the watermark's size, as a share of the tablet height (0.05-1)
-- grayscale: true = the logo is drawn in grey
-- personalAccents: the accents an officer may pick for their own tablet (see sast below)
-- missionControls: this department's own Mission controls (optional; see Config.MissionControls)
-- officerOptions: this department's own My options choices (optional; see Config.OfficerOptions)
Config.Departments = {
    sast = {
        label = 'San Andreas State Troopers',
        enabled = true,
        short = 'SAST',
        jobs = { 'sast' },
        supervisorGrade = 3,
        societyAccount = 'sast',
        theme = {
            primary = '#1f4e8c',
            accent = '#f2c230',
            background = '#0d1522',
            surface = '#152235',
            -- text    = '#ffffff',   -- optional; picked automatically for contrast when left out
            -- accents an officer may pick for their own tablet: a 6-digit hex colour, or { colour, level }
            -- to unlock it at that level. Leave it out to offer none. Primary, logo and watermark never change.
            personalAccents = {
                '#f2c230',
                '#4cc9f0',
                { colour = '#80ed99', level = 10 },
                { colour = '#ff8fab', level = 25 },
                { colour = '#c77dff', level = 40 },
            },
        },
        logo = {
            file = 'sast.png',
            watermark = true,
            opacity = 0.08,
            size = 0.6,
            grayscale = false,
        },
    },
    fib = {
        label = 'Federal Investigation Bureau',
        enabled = true,
        short = 'FIB',
        jobs = { 'fib' },
        supervisorGrade = 3,
        societyAccount = 'fib',
        theme = {
            primary = '#1c2541',
            accent = '#c9a227',
            background = '#0b0c10',
            surface = '#1a1b24',
            personalAccents = {
                '#c9a227',
                '#e9ecef',
                { colour = '#48cae4', level = 10 },
                { colour = '#f28482', level = 25 },
                { colour = '#b5e48c', level = 40 },
            },
        },
        logo = { file = 'fib.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
    },
    -- Example: to add BCSO, uncomment and edit this block, then put bcso.png in logos/ and restart.
    -- bcso = {
    --   label = "Blaine County Sheriff's Office", short = 'BCSO', jobs = { 'bcso' },
    --   supervisorGrade = 3, societyAccount = 'bcso',
    --   theme = { primary = '#5c4033', accent = '#d4a017', background = '#14100c', surface = '#231c16' },
    --   logo  = { file = 'bcso.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
    -- },
}

-- ============================================================================
--                                    NAMES
-- ============================================================================
-- English names an admin gives to ids (Admin UI → Settings → Names). Only these kinds: custody.offence.<id>,
-- profile.commend.kind.<id>, badge.<id>, bonus.<id> and penalty.<id>. A name changes text only, never an id.
Config.Labels = {
    -- ['custody.offence.loitering'] = 'Loitering',
}

-- ############################################################################
--                            PART 2 · NPC MISSIONS
-- Missions against NPCs: mission types, stars, the team size, where people appear and how they act,
-- the route and the map, the draw, mission calls, real calls and alerts, custody, events, the
-- built-in mission tweaks and the Mission Builder.
-- Usually changed here: the mission types' payouts, MissionCalls (how often calls come) and NpcDifficulty.
-- ############################################################################

-- ============================================================================
--                                MISSION TYPES
-- ============================================================================
-- The four mission types every mission belongs to. Usually changed here: payout (or in game, Admin UI -> Payouts).
-- label: the type's name on the tablet
-- points: leaderboard points for a finished run, config only (never editable in-game).
-- payout: default base cash payout in dollars. Supervisors and admins change it in-game;
-- admin-set values are stored permanently in cp_type_payouts.
-- dailyLimit: completed runs of this type per officer per day; nil = no limit.
Config.MissionTypes = {
    patrol = { label = 'Patrol', points = 60, payout = 250, dailyLimit = nil },
    training = { label = 'Training', points = 100, payout = 350, dailyLimit = nil },
    investigation = { label = 'Investigation', points = 160, payout = 600, dailyLimit = nil },
    tactical = { label = 'Tactical', points = 200, payout = 800, dailyLimit = nil },
}

Config.DisabledMissions = {}   -- mission ids to turn off (built-in or custom), e.g. { 'prison_break' }
-- Locations to turn off without removing them, by mission id: their labels (or numbers, 1 = the first), e.g.
-- { prison_break = { 'North gate' } }. Admin UI → Missions has an on/off switch for every mission and location.
Config.DisabledLocations = {} -- locations turned off, by mission id (see above)

-- ============================================================================
--                              DIFFICULTY (stars)
-- ============================================================================
-- Multipliers by a mission's difficulty: index 1, 2 or 3 stars.
-- 1.0 = stars change nothing, so a builder can't raise pay or points by picking 3 stars.
Config.Difficulty = {
    pointsByStars = { 1.0, 1.0, 1.0 }, -- points multiplier for 1, 2 and 3 stars
    cashByStars = { 1.0, 1.0, 1.0 },   -- cash multiplier for 1, 2 and 3 stars
}

-- ============================================================================
--                           SCALING BY PARTICIPANTS
-- ============================================================================
-- The first row whose maxParticipants >= the participant count is used.
Config.Scaling = {
    { maxParticipants = 1, tier = 'standard', count = 1.0, accuracy = 0, armour = 0, points = 1.00, cash = 1.00 },
    { maxParticipants = 2, tier = 'reinforced', count = 1.25, accuracy = 5, armour = 10, points = 1.10, cash = 1.15 },
    { maxParticipants = 4, tier = 'heavy', count = 1.5, accuracy = 10, armour = 25, points = 1.15, cash = 1.30 },
    { maxParticipants = 6, tier = 'major', count = 2.0, accuracy = 15, armour = 50, points = 1.20, cash = 1.50 },
    { maxParticipants = 8, tier = 'critical', count = 2.5, accuracy = 20, armour = 75, points = 1.25, cash = 1.75 },
}
-- See also Part 4 (Police teamwork): Cross-department missions.

Config.CrossDepartmentPoints = 1.10    -- points multiplier when 2+ departments are on a run

-- When the team shrinks mid-run (see When someone leaves mid-run)
Config.Rescale = {
    -- NPCs not yet spawned use the tier for the team that's left
    enabled = true,
    keepPayTierFor = { 'real_call', 'force_recall', 'downed' },  -- leave reasons that keep the points and cash tier
}

-- ============================================================================
--                    SPAWNING (where mission people appear)
-- ============================================================================
-- Where a mission's people may appear, so they never pop up next to, behind or all around your officers. A mission
-- asks for its spawn points here: a point that breaks a rule below is skipped, and a mission that gets too few points
-- waits for more. Distances are measured on the map (height does not count).
Config.Spawning = {
    -- false = people appear at the mission's points as before (no rule below is used; only the spawn point check,
    -- which you start yourself, still judges points by ground)
    enabled = true,
    -- Metres: an objective's people appear once an officer is this close to them (50-400, well inside the 424 m a
    -- player's game can see)
    activateRange = 150.0,
    minDistance = 40.0,              -- metres: a point closer than this to any officer is never used
    -- Metres: a point inside a building (walls hide it) closer than this to any officer is never used
    minDistanceIndoor = 15.0,
    -- Degrees: a point further than this off an officer's line to the scene (from where he stands towards the
    -- mission's points, whichever side he came in from) is behind him and never used. Only officers within
    -- activateRange of the point count (180 = off)
    behindAngle = 110.0,
    -- Degrees: all points of one wave fit in a slice this wide seen from the officers, so a wave never comes from every
    -- side at once (360 = off)
    maxSpread = 150.0,
    waveDelayMax = 20,               -- seconds a wave waits for points minDistance away before closer ones are allowed
    -- Metres: once a wave has waited waveDelayMax, a point this close to an officer may be used, never a closer one
    hardMin = 20.0,
    -- Seconds a wave of hostiles, a warrant's associates or a scatter's suspects (Prison Break's inmates, the raids'
    -- cooks and runners) may stay short of points (every point too close to or behind the officers, or a cuffed
    -- suspect still stands on it), counted from when they first had to wait. Once that time has passed, someone of the
    -- fight or objective has appeared and nobody of it is left to fight or catch, the ones that could not be placed
    -- are left out, so it can end (0 = never: they wait until the officers move away)
    leaveOutAfter = 45,
    -- true = a mission may place the next objective's people ahead of time, while your officers are still busy with
    -- the one before it, so they are already there when it starts instead of popping up around the officers (false =
    -- they appear only when their objective starts, as before)
    stageAhead = true,
    -- Metres: a raid's crew waiting in place before the breach stays calm until an officer comes this close to one of
    -- them (officers nearer to the breach entries than to him do not count) or hurts one; then they all wake and
    -- fight at once (0 = only a hurt one wakes them). They always wake when the fight starts
    stageWakeRange = 12.0,
    -- true = a warrant's armed associates appear only when an officer knocks, on their points 15 m or more from every
    -- officer, out of the officers' sight first and never behind the one at the door, instead of waiting beside the
    -- door from the start (false = they wait at their points from the start, as before)
    associatesAtKnock = true,
    -- Metres, nearest and furthest: a parked car's returning driver and a stolen car's thief appear this far from the
    -- car, on a footpath the game of the officer at the car finds in front of him, out of his sight first, and walk up
    -- to the car once that game has put them on the ground (no answer from his game: round the car at this distance,
    -- never closer than the nearest to any officer). With enabled = false: 14 m and 30 m round the car, as before
    contactRing = { 25.0, 40.0 },
    -- Metres: a scene (Suspicious Activity's people and car, each parked car of Parking Patrol) appears once an
    -- officer is within activateRange of it while every officer is further than the mission's approach distance
    -- (where the people react, 25 m) plus this from it, so it is already there before you are on top of it (after
    -- waveDelayMax: hardMin, never closer)
    sceneOutside = 10.0,
    -- Seconds a scene waits for officers standing closer than that before it appears anyway, with one warning in the
    -- console naming the mission and the place (move its start further out); 0 = it waits until they step back
    sceneWaitMax = 45,
    -- When Hostage Rescue's hostages appear: 'objective' = when their own objective starts (after the fight), on
    -- their points once an officer is near and every officer is minDistanceIndoor (15 m) or more from them;
    -- 'runStart' = when the run starts, before the fight, as before
    hostagesAt = 'objective',
    -- Seconds the hostages wait for officers standing closer than minDistanceIndoor before they appear on their points
    -- anyway (they are tied up and unarmed, and the rescue cannot go on without them), with one warning in the
    -- console; 0 = they wait until the officers step back
    hostagesWaitMax = 10,
    -- Metres (0-1.5) a car made on a point of the mission's road itself (Traffic Enforcement's violator, a race loop's
    -- waypoint, Armored Truck Escort's truck and ambush cars) is lifted over the road there, so it never starts inside
    -- the road surface (0 = on the road's own height). A mission's own pursuit car points are used as written
    vehicleLift = 0.5,
    -- Metres (0-400): a violator that comes after another one on the same road (Traffic Enforcement's second violator)
    -- appears this far up the road from the officer furthest up it, so it drives towards your officers wherever they
    -- worked the first stop (0 = at the first violator's point, as before)
    secondViolatorUpstream = 200.0,
    -- true = an Armored Truck Escort ambush car never appears on, next to (within minDistance) or behind the truck, nor
    -- on another vehicle: its slot slides further along the route instead, ahead of the truck and away from your
    -- officers (a lead car included). false = the cars use their ambush point's own slots only (they still wait for
    -- officers standing on them), and appear there even once the truck is past it, as before
    ambushAheadOnly = true,
    -- true = of the points a wave may use, the ones your officers cannot see (behind a building, a container or a
    -- vehicle, as the nearest officers' own games check it) are used first, so people appear out of sight instead of
    -- in the open in front of you; seen points are still used when there are not enough hidden ones. A Manhunt clue
    -- closer than minDistance to an officer appears only where those games say no officer can see it, or in sight at
    -- hardMin or further once it has waited waveDelayMax (false = the mission's own order and nobody is asked: such a
    -- clue waits until the officers are minDistance away, or hardMin after waveDelayMax)
    preferHidden = true,
    -- Milliseconds the server waits for the officers' games to say what they can see (100-5000); no answer in time =
    -- every point counts as seen (the distance rules above still apply). Also how long it waits for the footpath point
    -- of a returning driver or a thief (contactRing)
    losTimeoutMs = 1500,
    -- How a point is checked against the ground under it: each range is the lowest and highest height in metres of
    -- the point in the mission file over the ground there (used by the spawn point check in Admin UI -> Testing and by
    -- place below)
    ground = {
        -- Metres, lowest and highest: a person's point fits from 0.3 m under to 1.6 m over the ground (a standing
        -- person's point is about 1 m over it)
        pedAbove = { -0.3, 1.6 },
        vehicleAbove = { -0.2, 1.5 },    -- metres, lowest and highest: the same for a vehicle's point
        propAbove = { -0.1, 0.5 },       -- metres, lowest and highest: the same for an object's point (a clue, a stash)
        -- Metres (0-10): a point outside its range is put on the ground when that moves it at most this far up or
        -- down; one further off is reported as under the ground or floating
        snapWithin = 3.0,
    },
    -- Milliseconds (500-30000) a game waits for the ground around a point to load before it checks the point
    collisionTimeoutMs = 6000,
    -- Milliseconds (500-30000) a game waits for the inside of a building (a bank, a store) to load; still not loaded
    -- after this = the point is reported as "inside not loaded"
    interiorTimeoutMs = 5000,
    -- true = every new person, vehicle and object of a mission waits frozen where it appears until the game of an
    -- officer near it has checked the ground there and put it on the ground (by the ranges above); a point under the
    -- ground, floating, in water or in a wall is reported back instead and another of the mission's points is tried.
    -- false = they appear on the file's points as before
    place = true,
    -- Milliseconds (1000-60000) a new person, vehicle or object waits frozen for an officer's game to put it on the
    -- ground, counted while an officer is within activateRange of it and no officer's game is checking it (a big
    -- wave's later ones wait their turn there, at most 34 s plus collisionTimeoutMs and interiorTimeoutMs); then
    -- onTimeout
    placeTimeoutMs = 8000,
    -- How many times (0-5) a point an officer's game reports bad (under the ground, floating, in water, in a wall) is
    -- swapped for another point the mission may use there; after that, or with no other point, the last one is used
    -- as it is (one warning in the console)
    retries = 2,
    -- 'unfreeze' = a person, vehicle or object that no officer's game has put on the ground within placeTimeoutMs is
    -- let go where it stands, as before; 'delete' = it is removed and the mission treats it as killed (a hostage or an
    -- escort's truck removed this way fails that objective). A person or vehicle the mission only moved, such as a
    -- warrant's suspect who gives up at the door or the prisoner transport put on its parking point, is always let go
    -- where it stands
    onTimeout = 'unfreeze',
    -- true = a console line for each point skipped (shown while Config.Debug is on) and a warning when a wave had to
    -- use closer points
    log = true,
}

-- ============================================================================
--                              SUSPECT BEHAVIOUR
-- ============================================================================

Config.Npc = {
    tellSeconds = { 1.5, 3.0 },      -- how long a tell plays before a person runs or draws
    tellHints = true,                -- HUD hint ("Watch his hands") for participants within tellRange
    tellRange = 25.0,                -- metres
    feintRange = 6.0,                -- a feint needs no participant this close...
    feintAfter = 5,                  -- ...and nobody aiming for this many seconds
}

-- How NPCs feel. It never changes points or cash. Each preset (and custom) has:
-- accuracyAdd: added to armed NPCs' accuracy (0-100 scale; -8 = a little worse aim)
-- armourAdd: armour points added to armed NPCs (0 = none)
-- healthMult: × NPC health (1.15 = 15 % more)
-- surrenderMult: × how readily an NPC gives up (1.3 = gives up more easily, 0.7 = holds out longer)
-- fleeMult: how long runners keep running (Config.Flee): 1.2 = 20 % longer
Config.NpcDifficulty = {
    preset = 'normal',               -- 'easy' | 'normal' | 'hard' | 'custom'
    -- the values used when preset = 'custom'
    custom = { accuracyAdd = 0, armourAdd = 0, healthMult = 1.0, surrenderMult = 1.0, fleeMult = 1.0 },
    presets = {
        easy = { accuracyAdd = -8, armourAdd = 0, healthMult = 0.85, surrenderMult = 1.3, fleeMult = 0.8 },
        normal = { accuracyAdd = 0, armourAdd = 0, healthMult = 1.0, surrenderMult = 1.0, fleeMult = 1.0 },
        hard = { accuracyAdd = 8, armourAdd = 15, healthMult = 1.15, surrenderMult = 0.7, fleeMult = 1.2 },
    },
}

-- How hard armed mission NPCs fight back. Only mission NPCs and the officers on their run are changed, and only
-- while the run is live. For every number here: lower = easier for your officers.
Config.NpcCombat = {
    enabled = true,                  -- false = NPCs fight as GTA makes them (every value below is ignored)
    -- The only weapons a mission NPC is ever given. Automatic weapons (SMGs, rifles, machine guns) are never given,
    -- even when one is added here.
    weapons = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_HEAVYPISTOL', 'WEAPON_PUMPSHOTGUN' },
    -- A mission that names a weapon outside the list above gets the weapon this list gives for it...
    replace = {
        WEAPON_MICROSMG = 'WEAPON_PISTOL',
        WEAPON_SMG = 'WEAPON_COMBATPISTOL',
        WEAPON_ASSAULTRIFLE = 'WEAPON_HEAVYPISTOL',
    },
    fallback = 'WEAPON_PISTOL',      -- ...or this one when the list has none for it
    ammo = 60,                       -- rounds each armed NPC gets
    accuracyScale = 0.7,             -- NPC accuracy (after the team size and Config.NpcDifficulty) times this...
    accuracyMax = 18,                -- ...and never above this (0-100; bosses and shots from cars too)
    shootRate = 60,                  -- how fast NPCs pull the trigger (0-1000)
    firingPattern = 'single',        -- 'single' (one shot at a time), 'burst' (short bursts), 'delayed' (a pause
                                     -- before each shot) or 'default' (GTA picks)
    abilityMax = 1,                  -- combat skill at most: 0 poor, 1 average, 2 professional
    noCharge = true,                 -- NPCs never charge at officers
    aiDamage = 0.5,                  -- damage of NPC bullets (1.0 = normal GTA damage, 0.5 = half)
    aiMeleeDamage = 0.5,             -- damage of NPC punches and melee weapons (1.0 = normal)
    reassertAiDamage = true,         -- true = the run's NPC damage value is set again every 2 s (other scripts
                                     -- such as Crimson-Contracts share it); false = set once at the start (the old way)
    officerDefense = 1.0,            -- damage officers on a run take from every weapon, players' too (1.0 = off)
    noCriticalHits = true,           -- officers on a run take no extra headshot damage (it hurts like a body shot)
    cancelLethalHeadshots = true,    -- the server drops a one-shot kill by a mission NPC on an officer of its run...
    lethalCancelAbove = 0.75,        -- ...who still has at least this share of his health (0.25-1, 0.75 = three
                                     -- quarters). The shot that finishes off a hurt officer always counts
    playerHitDropsProtection = false, -- true = an officer on an NPC mission loses noCriticalHits and officerDefense for
                                      -- the rest of that run once a real player who is not on the run shoots him
}

-- How long a suspect who runs from your officers can keep running. GTA's NPCs never tire, so the server times every
-- mission NPC that runs on foot (time in a car does not count): first a sprint, then a jog, then a walk, then worn
-- out, and he slows down to match. A worn-out runner gives up when an officer gets close. Config.NpcDifficulty's
-- fleeMult stretches every time here ('hard' runners last 20 % longer, 'easy' ones 20 % shorter).
Config.Flee = {
    enabled = true,                  -- false = suspects run as GTA makes them: they never tire
    sprintSeconds = 10,              -- seconds a runner sprints before he slows to a jog
    jogSeconds = 12,                 -- seconds he then jogs before he slows to a walk
    walkSeconds = 8,                 -- seconds he then walks before he is worn out
    -- Each suspect lasts up to this share longer or shorter, rolled once per suspect from the run's seed (0.25 = 25 %,
    -- 0 = every suspect lasts the same)
    jitter = 0.25,
    -- Seconds with no officer within recoverRange before a runner gets his breath back and sprints again
    recoverSeconds = 20,
    recoverRange = 60.0,             -- metres: an officer this close stops a runner from getting his breath back
    armedTire = true,                -- false = a suspect who carries a weapon you can see never tires
    jogRate = 0.95,                  -- a jogging runner's speed: 1.0 = a normal jog, 0.9 = 10 % slower (0.5-1.0)
    walkRate = 0.85,                 -- a walking or worn-out runner's speed: 1.0 = a normal walk (0.5-1.0)
    windedClipset = true,            -- true = a tired runner looks it: he jogs, then walks winded
    -- What a worn-out runner does when an officer comes within giveUpRange: 'surrender' (he gives up and kneels),
    -- 'handsUp' (he gives up and stands with his hands up) or 'walk' (he walks on and never gives up on his own)
    exhausted = 'surrender',
    giveUpRange = 30.0,              -- metres: a worn-out runner gives up when an officer is this close (5-100)
    -- true = a runner, cook or inmate who scatters (Gang Hideout Raid, Drug Lab Raid, Prison Break) flees along the
    -- escape route that starts nearest where he appears, so nobody runs back across the site past your officers
    -- (routes that start about as near, within 5 m, take turns); false = the routes take turns wherever he appears
    nearestRoute = true,
}

-- ============================================================================
--                              ROUTE TO THE START
-- ============================================================================

Config.Route = {
    -- true = officers must follow the GPS route to the mission start; leaving it for abandonAfter seconds ends their
    -- run as Abandoned. false = the route is still shown, but leaving it never ends a run. A run keeps the value it was
    -- accepted with; a test run follows its own Start route switch
    required = true,
    sampleEvery = 50.0,    -- metres between points taken from the GPS route
    reportEvery = 2,       -- seconds between client reports
    reportTimeout = 10,    -- no report for this long counts as off route
    maxDeviation = 120.0,  -- metres from the line before a participant is off route
    warnAfter = 10,        -- seconds off route before the warning
    abandonAfter = 30,     -- seconds off route in one stretch before Abandoned (back on route resets it)
    maxRecalcs = 2,        -- Recalculate route taps per participant per run
    maxDrift = 1000.0,     -- server check: metres further from the start than the closest they have been
    -- metres: once the run is In progress, an officer still on his way follows the action instead of the start: his
    -- GPS leads to the objective, his route is no longer checked, and he arrives this close to the objective (or at
    -- the start). 0 = only the start counts, as before
    lateArriveRange = 150.0,
    -- seconds: an officer who follows the action gets this long from then on to reach it, so a partner who left late
    -- is not dropped by the start timeout (Config.Limits.startTimeout) while he chases. Never less time than he had.
    -- The HUD and the tablet show the time left in the last 2 minutes. 0 = he keeps the start deadline, as before
    followActionSeconds = 300,
}

-- ============================================================================
--                                 MAP MARKERS
-- ============================================================================
-- How the objective your officers are on shows on their map: one blip (for a fight or a search area, a circle and its
-- centre) with one GPS line to it. While an officer still drives to the start, the line to the start is the only one he
-- gets from us; one who has set a waypoint of his own gets no objective line. Under kinds, each kind of blip has a
-- sprite (the blip's picture, by its id), a colour (a colour id: 5 = yellow, go here; 1 = red, enemy; 17 = orange,
-- fleeing or needs a follow-up; 3 = blue, friendly; 2 = green, safe point) and a scale (its size, 1.0 = normal).
-- nextScale, bossScale, surrenderedScale, followUpColour and setbackColour are the same for the next checkpoint, a
-- boss, a suspect who gave up (the same size near you and far away), a point to follow up and a device set back.
-- Sprite and colour ids: docs.fivem.net/docs/game-references/blips/
Config.Markers = {
    enabled = true,              -- false = no objective blip or line from Crimson-Police (the missions' own blips stay)
    route = true,                -- false = the objective blip shows, but no GPS line to it
    routeColour = 5,             -- colour of the GPS line to an objective (5 = yellow, 1 = red, 3 = blue)
    routeOffWithin = 40.0,       -- metres: the line turns off this close to the objective (inside a circle: off)
    trackEvery = 2,              -- seconds between the positions the server sends of moving objectives (cars, people)
    farTargets = true,           -- true = a car or suspect too far away for your game shows where the server says
    shortRange = false,          -- false = objective blips show at the edge of the radar however far away they are
    flashSeconds = 5,            -- seconds a new objective blip flashes (0 = no flash)
    setbackFlash = true,         -- true = a device that was set back (Drug Lab Raid: Ventilate) flashes until fixed
    category = 2,                -- the map legend: 2 = shows the distance to the blip, 1 = no distance
    areaAlpha = 80,              -- how solid the map circles are: 0 = invisible, 255 = solid
    -- true = the yellow Mission start pin stays on the map for the whole drive, with a GPS line of its own while your
    -- waypoint to the start is gone (you cleared it or set your own); false = only the waypoint shows the start
    startBlip = true,
    startCircleMin = 200.0,      -- metres: a mission start at least this wide shows as a circle on the map (Manhunt)
    -- What Radio Silence hides once the officers are at the start: 'area' = each objective's circle or its one blip
    -- stays (of several doors or devices only your nearest), without a GPS line and without blips on people and cars;
    -- 'none' = every objective blip; 'full' = nothing. The drive to the start, the prisoner van and the tow truck
    -- always show
    radioSilence = 'area',
    -- seconds: with 'area', a 200 m circle shows where a moving suspect or car was, moved this often (0 = off)
    radioSilenceLastKnown = 0,
    hudLine = true,              -- true = the HUD shows the objective's name and how far it is
    objectiveGps = true,         -- true = an Objective GPS button on the tablet puts a waypoint on the objective
    serviceVehicles = true,      -- true = a prisoner van or tow truck coming to you shows on the map
    -- How each kind of blip looks: sprite (blip id), colour id and size. Yellow = go here, red = enemy, orange =
    -- fleeing or needs a follow-up, blue = friendly, green = safe point
    -- sprite: the blip's picture, by its blip id (docs.fivem.net/docs/game-references/blips/)
    -- colour: the blip's colour id (5 = yellow, 1 = red, 17 = orange, 3 = blue, 2 = green)
    -- scale: the blip's size (1.0 = normal, 0.5 = half)
    -- nextScale: the size of the next checkpoint's blip
    -- bossScale: the size of a boss's blip
    -- surrenderedScale: the size of a suspect who gave up (the same near you and far away)
    -- followUpColour: the colour id of a point to follow up
    -- setbackColour: the colour id of a device that was set back
    kinds = {
        start = { sprite = 162, colour = 5, scale = 1.0 },                      -- the mission start
        checkpoint = { sprite = 1, colour = 5, scale = 1.0, nextScale = 0.7 },  -- a checkpoint (nextScale: the next)
        searchArea = { sprite = 162, colour = 5, scale = 0.9 },                 -- the centre of a search area
        clue = { sprite = 1, colour = 5, scale = 0.7 },                         -- a clue in a search area
        fightArea = { sprite = 84, colour = 1, scale = 0.9 },                   -- the centre of a fight
        hostile = { sprite = 1, colour = 1, scale = 0.6, bossScale = 0.9 },     -- an armed hostile (bossScale: a boss)
        -- a suspect: stopped or armed (surrenderedScale: one who gave up)
        suspect = { sprite = 1, colour = 1, scale = 0.7, surrenderedScale = 0.6 },
        fleeing = { sprite = 1, colour = 17, scale = 0.8 },                     -- a suspect on the run
        vehicle = { sprite = 225, colour = 1, scale = 0.9 },                    -- a suspect's car
        contact = { sprite = 280, colour = 5, scale = 0.7 },                    -- a person to talk to
        contactVehicle = { sprite = 225, colour = 5, scale = 0.7 },             -- a car to check
        escort = { sprite = 67, colour = 3, scale = 1.0 },                      -- the vehicle you escort
        destination = { sprite = 38, colour = 5, scale = 0.9 },                 -- where the escort goes
        hostage = { sprite = 280, colour = 3, scale = 0.8 },                    -- a hostage
        safePoint = { sprite = 38, colour = 2, scale = 0.9 },                   -- where the hostages go
        scene = { sprite = 162, colour = 5, scale = 0.9 },                      -- a scene to work
        point = { sprite = 1, colour = 5, scale = 0.8, followUpColour = 17 },   -- a point to check (or follow up)
        device = { sprite = 1, colour = 5, scale = 0.8, setbackColour = 17 },   -- a device to work (or one set back)
        prisonerVan = { sprite = 285, colour = 3, scale = 0.8 },                -- a prisoner van coming to you
        towTruck = { sprite = 68, colour = 3, scale = 0.8 },                    -- a tow truck coming to you
        objective = { sprite = 162, colour = 5, scale = 0.9 },                  -- any other objective
    },
}

-- ============================================================================
--                                MISSION BLIPS
-- ============================================================================
-- Extra map blips for the other parts of a mission: the prisoner van, tow truck and coroner van and where each one
-- waits for you, evidence, the cars and people of a scene, devices, hiding spots once found, ambush cars once they
-- appear, the hospital, your partners and a live case's reported points. They show on the minimap and the big map.
-- Shipped off: with enabled = false nothing below shows and the map is as before (Map markers above still marks the
-- objective). The server decides what each officer gets: a real player suspect's live position never shows (a live
-- case keeps its last-reported points only), nothing hidden shows before it is found, and Radio Silence still hides
-- people and cars ('area') or everything ('none') as Config.Markers.radioSilence says.
Config.MissionBlips = {
    enabled = false,             -- master switch: false = no extra mission blips at all (each part's on is ignored)
    refreshEvery = 3,            -- seconds between the server's checks of what each officer's map should show
    -- Each part of a mission that can get a blip. The prisoner van and tow truck show only when Map markers does not
    -- already show them (Config.Markers.serviceVehicles off)
    -- on: true = this part shows (only while enabled is true)
    -- sprite: the blip's picture, by its blip id (docs.fivem.net/docs/game-references/blips/)
    -- colour: the blip's colour id (5 = yellow, 1 = red, 17 = orange, 3 = blue, 2 = green, 0 = white)
    -- scale: the blip's size (1.0 = normal, 0.5 = half)
    -- label: its name on the map legend ('' = the built-in name)
    -- shortRange: true = on the minimap only when near; false = at the minimap's edge however far away it is
    parts = {
        prisonerVan = { on = false, sprite = 285, colour = 3, scale = 0.8, label = '', shortRange = false },
        prisonerDrop = { on = false, sprite = 60, colour = 3, scale = 0.7, label = '', shortRange = false },
        towTruck = { on = false, sprite = 68, colour = 3, scale = 0.8, label = '', shortRange = false },
        impoundDrop = { on = false, sprite = 50, colour = 3, scale = 0.7, label = '', shortRange = false },
        coronerVan = { on = false, sprite = 67, colour = 40, scale = 0.8, label = '', shortRange = false },
        coronerDrop = { on = false, sprite = 1, colour = 40, scale = 0.7, label = '', shortRange = false },
        evidence = { on = false, sprite = 1, colour = 0, scale = 0.6, label = '', shortRange = true },
        suspectVehicle = { on = false, sprite = 225, colour = 1, scale = 0.7, label = '', shortRange = false },
        parkedCar = { on = false, sprite = 225, colour = 0, scale = 0.6, label = '', shortRange = true },
        witness = { on = false, sprite = 280, colour = 0, scale = 0.6, label = '', shortRange = true },
        hostage = { on = false, sprite = 280, colour = 3, scale = 0.7, label = '', shortRange = false },
        device = { on = false, sprite = 1, colour = 5, scale = 0.6, label = '', shortRange = true },
        hidingSpot = { on = false, sprite = 1, colour = 17, scale = 0.6, label = '', shortRange = true },
        sceneProp = { on = false, sprite = 1, colour = 0, scale = 0.5, label = '', shortRange = true },
        ambush = { on = false, sprite = 225, colour = 1, scale = 0.6, label = '', shortRange = false },
        hospitalDrop = { on = false, sprite = 61, colour = 1, scale = 0.8, label = '', shortRange = false },
        partner = { on = false, sprite = 1, colour = 3, scale = 0.7, label = '', shortRange = false },
        reportedPoint = { on = false, sprite = 1, colour = 17, scale = 0.8, label = '', shortRange = false },
    },
    -- Who sees a part, by part name; a part without rules shows to every officer on the run. Every rule is optional and
    -- all must match: departments = { 'sast' }, jobs = { 'police' }, grade = the lowest grade level, missionTypes =
    -- { 'patrol' }, missions = { 'mission_id' }, roles = 'all' | 'leader' (the unit leader) | 'supervisor'
    -- Example: partner = { departments = { 'sast' }, roles = 'leader' },
    rules = {},
}

-- ============================================================================
--                                 RANDOM DRAW
-- ============================================================================

Config.Draw = {
    avoidLast = 1,              -- never repeat the last mission in that type
    avoidLastLarge = 2,         -- skip the last two when the pool has largePool+ missions
    largePool = 4,              -- missions in a type's pool that make it large (see avoidLastLarge)
    playerClearance = 75.0,     -- skip locations with a non-participant within this many metres
    zoneClearance = 200.0,      -- skip a location within this many metres of another active run's location
                                -- (any mission), while another is free
    hardClearance = 100.0,      -- never draw a location within this many metres of another active run's
                                -- location, even when nothing else is free (0 = off: zone clearance only)
    avoidLastLocations = 2,     -- skip the last N locations any participant played in this mission, while
                                -- another is free
    locationFreshness = 3600,   -- seconds: a location used server-wide this recently gets half the weight
}

-- ============================================================================
--                           DISPATCH (MISSION CALLS)
-- ============================================================================
-- Tablet-only NPC calls. The first unit to claim one gets a random mission of that type that starts in
-- the call's area. Mission calls are never sent to SC-Dispatch, and real calls always come first.
Config.MissionCalls = {
    enabled = true,                  -- true = the server posts NPC mission calls to the tablet
    checkEvery = 10,                 -- seconds between server checks
    -- Types that can be called: how often (weight) and priority (1 = highest)
    -- weight: how often this type is called against the others (5 vs 2 = two and a half times as often; 0 = never)
    -- priority: 1 = highest; a higher-priority call shows first on the board
    types = {
        patrol = { weight = 5, priority = 3 },
        investigation = { weight = 3, priority = 2 },
        tactical = { weight = 2, priority = 1 },
        -- training = { weight = 1, priority = 3 },   -- training and the Weekly Boss are never called
    },
    unitsPerCall = 2,                         -- at most one open call per this many idle units...
    maxOpen = 4,                              -- ...and never more than this many open at once
    spawnEvery = { 60, 150 },                 -- seconds between new calls, random in this range
    offerTime = 180,                          -- seconds a call stays open
    lapsedShown = 10,                         -- seconds a lapsed call stays on screen
    claimWindowMs = 1500,                     -- claims this soon after the first are ranked (0 = pure first click)
    priorityWindow = 15,                      -- seconds during which only nearby units may claim...
    priorityRadius = 1500.0,                  -- ...within this many metres of the area's centre
    -- A call names its area to a viewer only when the viewer's eligible pool there (after unit size,
    -- no-repeat, cooldowns and daily limits) has this many missions and locations; else "County-wide".
    minMissionsPerArea = 2,
    minLocationsPerArea = 3,                                   -- locations the area needs before a call names it
    countyWeightKm = 2.0,                                      -- county-wide draws weight locations by 1 / (1 + km / this)
    titles = { patrol = 8, investigation = 6, tactical = 6 },  -- flavour titles per type (mc.title.<type>.<n>)
    eligibilityCache = 10,                                     -- seconds an officer's cached eligibility may be reused
    recentShown = 5,                                           -- calls in the Recent calls list
    -- A claim dropped before anyone reached the start reopens once
    -- enabled: false = it never reopens
    -- time: seconds the reopened call stays open
    reopen = { enabled = true, time = 120 },
    -- +10% of P (points only) for reaching the start within distance ÷ speed (m/s) + grace (seconds)
    -- Server-posted calls only: paged and staff-created calls never earn it.
    -- pctOfP: the bonus as a share of P (0.10 = +10 %)
    -- speed: metres per second the target time allows for the distance
    -- grace: seconds added to the target time
    rapidResponse = { pctOfP = 0.10, speed = 20.0, grace = 45 },
    pageTime = 30,                   -- seconds a paged call is offered only to the paged unit
    -- seconds between calls created by the same supervisor (the issuer's own unit can never be paged, and can't claim
    -- a call the issuer paged or created)
    staffCooldown = 120,
    claimRate = 1500,                -- milliseconds between claim attempts per player
    realCallStrip = true,            -- show the read-only SC-Dispatch real-call count
    realCallCache = 15,              -- seconds
    -- A location belongs to the area whose centre is nearest. Labels show on the calls.
    areas = {
        { key = 'south_ls', label = 'South Los Santos', center = vec3(150.0, -1750.0, 29.0) },
        { key = 'downtown', label = 'Downtown', center = vec3(-150.0, -850.0, 30.0) },
        { key = 'west_ls', label = 'West Los Santos', center = vec3(-1250.0, -650.0, 25.0) },
        { key = 'vinewood', label = 'Vinewood', center = vec3(250.0, 250.0, 105.0) },
        { key = 'east_ls', label = 'East Los Santos', center = vec3(1100.0, -1250.0, 40.0) },
        { key = 'port', label = 'Port & Airport', center = vec3(100.0, -2700.0, 6.0) },
        { key = 'senora', label = 'Grand Senora', center = vec3(1400.0, 3200.0, 40.0) },
        { key = 'north', label = 'Grapeseed & Paleto', center = vec3(700.0, 5600.0, 35.0) },
        { key = 'west_county', label = 'West Blaine County', center = vec3(-2500.0, 2000.0, 20.0) },
    },
}

-- ============================================================================
--                                  REAL CALLS
-- ============================================================================

Config.Calls = {
    npcCallPrefix = 'npccall-', -- SC-NPCPolice call ids start with this; those calls never end a run
    -- about a participant: not real calls for their partners
    ownRunCallPrefixes = { 'playerdown_', 'playerdead_', 'emsdown_', 'emshelp_', 'panic_' },
    dodgeWindow = 60,           -- un-marking responding within this many seconds makes it a normal abandon
    respondingExpiry = 1200,    -- seconds; a responding entry with no update expires (auto-cleared calls fire no event)
}

-- ============================================================================
--                              ALERT SUPPRESSION
-- ============================================================================
-- The flag is the crimsonArena state bag, which SC-Dispatch and SC-Ambulance
-- already check; its name is fixed in those resources, so it is not configurable.
Config.Alerts = {
    -- clear a shots-fired call from a participant within this many metres of their mission (person-down and dead
    -- calls are cleared while the flag is on)
    backstopRadius = 300.0,
    backstopDelay = 1,      -- seconds to wait for SC-Dispatch to create the call before clearing it
}

-- ============================================================================
--                             DOWNED PARTICIPANTS
-- ============================================================================

Config.Downed = {
    checkEvery = 2,     -- seconds between downed checks
    pickupDelay = 15,   -- seconds down, with no EMS on duty, before the pick-up
    dropOffs = {        -- the nearest one is used; defaults are the hospitals' check-in points
        vec3(308.19, -595.35, 43.29),   -- Pillbox Hill, from qbx_ambulancejob config/shared.lua:62
        vec3(-254.54, 6331.78, 32.43),  -- Paleto Bay, from qbx_ambulancejob config/shared.lua:76
    },
}

-- ============================================================================
--                          POLICE ACTIONS AND CUSTODY
-- ============================================================================
-- See also Part 3 (Player vs police): a real suspect's cuffs and detain are timed in Config.RealSuspects.

-- What officers do with the people and cars of a mission (talk, frisk, search, cite, arrest, impound) and the vans
-- that come for them. Usually changed here: times (how long each action takes) and the chances.
-- The prisoner van (transport), tow truck (tow) and coroner van (coroner) have:
-- model: the vehicle model it comes in
-- driver: the ped model that drives it
-- spawnDistance: metres { nearest, furthest } from the scene where it appears
-- leaveAfter: seconds after the objective that called it ends before it drives off
-- bagProp: the body bag prop the coroner uses
-- enabled: false = no tow truck comes; the car fades out instead
Config.Custody = {
    times = {                        -- seconds each action's progress bar takes
        talk = 4,                    -- talk to a person and check their ID
        frisk = 4,                   -- frisk a person
        detain = 3,                  -- detain (cuff) a person
        searchPerson = 4,            -- search a person
        lookInside = 2,              -- look inside a car
        runPlate = 3,                -- run a plate
        inspect = 3,                 -- inspect a car
        orderOut = 2,                -- order a person out of a car
        searchVehicle = 8,           -- search a car
        warn = 2,                    -- give a verbal warning
        cite = 6,                    -- write a citation
        release = 2,                 -- release a person
        impound = 10,                -- impound a car
        noAction = 1,                -- no action
        explain = 4,                 -- explain the citation
        escort = 1,                  -- start or stop escorting a person
        seat = 2,                    -- place a person in a vehicle
        handover = 4,                -- hand a person over to the prisoner van
    },
    reach = {                        -- metres, checked with server-side coordinates
        person = 2.0,                -- to act on a person on foot (every other action)
        frisk = 1.5,                 -- to frisk a person
        vehicle = 3.0,               -- to act on a car or a person seated in one
        plateFromVehicle = 20.0,     -- Run plate from the driver seat of any vehicle
        seatVehicle = 5.0,           -- to seat a person in a vehicle
        van = 20.0,                  -- Hand over moves escorted and seated people this close to the van
    },
    -- chance a person agrees to a vehicle search
    consent = { clean = 0.60, guilty = 0.15 },
    admission = 0.20,                -- chance a guilty person admits it when talked to (probable cause)
    handcuffsItem = false,           -- e.g. 'handcuffs': Detain and Cuff suspect need it (checked, not used)
    evidenceItem = false,            -- e.g. 'evidence_bag': one per participant, removed at the run's end
    releaseDespawn = 30,             -- seconds before a released person or car is removed
    actionSlack = 0.5,               -- seconds an action's finish may come early (begin → finish check)
    -- Cues rolled with a guilty truth, so contraband in a car can usually be found lawfully.
    cues = { plainView = 0.40, odour = 0.30 },
    -- Mission vehicle plates: prefix + random letters and digits (8 characters in all), rerolled up to
    -- 5 times when player_vehicles already has the plate.
    plates = { prefix = 'CP', length = 8 },
    -- Service vehicles (transport, tow, coroner): driven by the nearest participant's client.
    serviceTimeout = 60,             -- seconds to park or load before the fallback (placed / faded out)
    serviceHandoff = 250.0,          -- metres: AI moves to another participant beyond this
    -- Metres (10-100): a prisoner van, tow truck or coroner van never appears or is put down closer than this to any
    -- player. After serviceTimeout with its parking point taken by an officer it comes to a road point beside the scene
    -- instead (or waits until the officer steps away); a tow truck that never got a road point fades the car out
    serviceClearance = 30.0,
    transport = {                    -- the prisoner van
        model = 'policet',
        driver = 's_m_y_cop_01',
        spawnDistance = { 150.0, 250.0 },
        parkWithin = 60.0,           -- metres: with no transport point it parks anywhere this close to the scene
        leaveAfter = 60,             -- seconds after the objective that called it ends; called again if needed
    },
    tow = {                          -- the tow truck; enabled = false fades the car out instead
        enabled = true,
        model = 'flatbed',
        driver = 's_m_m_trucker_01',
        spawnDistance = { 150.0, 250.0 },
        leaveAfter = 45,
    },
    coroner = {
        model = 'burrito3',
        driver = 's_m_y_autopsy_01',
        bagProp = 'xm_prop_body_bag',
        spawnDistance = { 150.0, 250.0 },
    },
    offences = {                     -- what a citation can name (labels: locale custody.offence.<id>)
        -- on a person or driver
        person = {
            'speeding',
            'reckless',
            'no_licence',
            'suspended_licence',
            'expired_registration',
            'open_container',
            'loitering',
            'possession_small',
            'equipment',
        },
        vehicle = { 'expired_meter', 'no_permit', 'no_parking', 'hydrant', 'loading_zone' },  -- on a parked car
    },
    -- Hidden truths, as weights (how likely each is against the others; 0 = never). A mission objective names the
    -- set (profileSet), then the person or car's role (person, driver, passenger, vehicle).
    -- clean: nothing to find
    -- minor: a small offence worth a citation
    -- warrant: wanted on a warrant (arrest)
    -- narcotics: carries drugs (arrest)
    -- tools: carries burglary tools (arrest)
    -- armed: carries an illegal weapon (arrest); the only truth that can turn hostile
    -- suspended: drives on a suspended licence
    -- intoxicated: drives drunk or high
    -- evading: fleeing the police (arrest)
    -- legal: a car with nothing wrong
    -- stolen: a stolen car (impound)
    -- violation: a parking violation (see parkingRules)
    profileSets = {
        scene = {
            person = { clean = 35, minor = 15, warrant = 15, narcotics = 15, tools = 12, armed = 8 },
            vehicle = { legal = 85, stolen = 15 },
        },
        traffic = {
            driver = { clean = 50, minor = 20, suspended = 10, warrant = 8, intoxicated = 7, narcotics = 3, armed = 2 },
            passenger = { clean = 70, warrant = 12, narcotics = 10, armed = 8 },
            vehicle = { legal = 90, stolen = 10 },
        },
        parking = {
            vehicle = { legal = 45, violation = 50, stolen = 5 },
        },
        stolenCar = {
            driver = { evading = 60, warrant = 25, armed = 15 },
            passenger = { evading = 60, warrant = 20, armed = 20 },
            vehicle = { stolen = 100 },
        },
    },
    -- Demeanour weights by truth (how likely each is against the others). Only armed people can be hostile.
    -- compliant: does what officers say
    -- nervous: complies, but shows it
    -- evasive: avoids questions and stalls
    -- runner: runs when officers come close
    -- hostile: draws a weapon
    demeanour = {
        clean = { compliant = 80, nervous = 15, evasive = 5 },
        minor = { compliant = 60, nervous = 30, evasive = 10 },
        suspended = { compliant = 55, nervous = 35, evasive = 10 },
        warrant = { compliant = 35, nervous = 25, evasive = 15, runner = 25 },
        narcotics = { compliant = 40, nervous = 35, evasive = 10, runner = 15 },
        tools = { compliant = 40, nervous = 30, evasive = 15, runner = 15 },
        intoxicated = { compliant = 60, nervous = 25, evasive = 15 },
        armed = { compliant = 30, nervous = 20, runner = 20, hostile = 30 },
        evading = { compliant = 30, nervous = 20, runner = 50 },
    },
    -- Parking: which spot rules make a violation ticket-level ('cite') or tow-level ('impound').
    parkingRules = {
        metered = 'cite',            -- an expired meter
        permit = 'cite',             -- a permit-only spot
        no_parking = 'impound',      -- a no-parking spot
        hydrant = 'impound',         -- in front of a hydrant
        loading = 'impound',         -- a loading zone
        free = false,                -- a free spot is legal, or the car is stolen
    },
}

-- ============================================================================
--                                  DECISIONS
-- ============================================================================
-- The point value of each grade is in Config.Bonuses (correct_disposition, wrongful_arrest, ...).
Config.Decisions = {
    -- releasing a person after their warrant or weapon reached the decider fails the case
    failOnKnownDanger = true,
    -- No action or a citation for a car whose stolen plate reached the decider fails the case
    failOnKnownStolen = true,
    confirmKnownErrors = true,          -- a case-failing choice asks "this will fail the case" first
    undiscoverableIsOk = true,          -- Release or No action is Acceptable when no lawful path existed
    undecidedAtEnd = 'missed_offence',  -- what a contact still undecided at the end counts as
    debrief = true,                     -- list every decision on the result screen and in history
}

-- ============================================================================
--                                SPECIAL EVENTS
-- ============================================================================

-- Extra fun on top of the missions: the Type of the Day, twists officers choose and the Weekly Boss. Usually
-- changed here: todMultiplier and the twists' points and cash.
Config.Events = {
    typeOfTheDay = true,     -- true = one mission type a day earns the points multiplier below
    todMultiplier = 2.0,     -- points only
    -- share of runs that also get one random twist on top of the ones the officers chose (0 = never: officers
    -- choose their own twists when they take a mission; 0.25 = one run in four)
    modifierChance = 0,
    armoredArmour = 50,      -- Armored Hostiles: extra armour on armed NPCs
    timeCrunchCut = 0.25,    -- Time Crunch: share of the time limit removed
    -- The Weekly Boss: one big mission on the days below
    -- enabled: true = the Weekly Boss shows on the Mission Board on its days; false = never
    -- days: the weekdays it is on, in lower case ('monday' to 'sunday'), the rest of the week it is off
    -- points: leaderboard points for finishing it
    -- payout: dollars for finishing it (until an admin sets a mission payout for it)
    weeklyBoss = { enabled = true, days = { 'friday', 'saturday', 'sunday' }, points = 500, payout = 2500 },
    -- Twists the officers may choose when they take a mission from the Mission Board or a mission call (the unit
    -- leader decides for the unit). Each chosen twist adds its own reward and they stack, up to twistMaxPoints and
    -- twistMaxCash. Rewards are paid only for a completed run. Never on the Weekly Boss, test runs or
    -- Cross-Department Missions.
    twists = {
        armored_hostiles = {     -- armed NPCs get armoredArmour extra armour (offered only where armed NPCs spawn)
            enabled = true,      -- false = officers cannot choose it and it is never rolled
            points = 0.25,       -- share of P it adds (0.25 = +25 % points; 0 = no extra points)
            cash = 1.25,         -- cash multiplier (1.25 = x1.25 cash; 1.0 = no extra cash)
        },
        time_crunch = {          -- the time limit is timeCrunchCut shorter
            enabled = true,      -- false = officers cannot choose it and it is never rolled
            points = 0.20,       -- share of P it adds (0.20 = +20 % points; 0 = no extra points)
            cash = 1.20,         -- cash multiplier (1.20 = x1.20 cash; 1.0 = no extra cash)
        },
        radio_silence = {        -- the map hides what Config.Markers.radioSilence says
            enabled = true,      -- false = officers cannot choose it and it is never rolled
            points = 0.25,       -- share of P it adds (0.25 = +25 % points; 0 = no extra points)
            cash = 1.25,         -- cash multiplier (1.25 = x1.25 cash; 1.0 = no extra cash)
        },
    },
    twistMaxPoints = 0.70,   -- the most all chosen twists add together, as a share of P (0.70 = +70 % points)
    twistMaxCash = 1.95,     -- the highest cash multiplier all chosen twists give together (the multipliers multiply)
}

-- ============================================================================
--                           BUILT-IN MISSION TWEAKS
-- ============================================================================
-- Change built-in missions without editing their files, so the change survives updates. Every tweak is
-- checked by the same rules as the file; a tweak that breaks one is ignored with a console warning.
-- Allowed keys: cooldown, timeLimit, startTimeout, disabledLocations (labels), peds, vehicles, weapons.
-- weapons replaces every weapon list of the mission (waves, ambushes, associates); a boss carries its last one.
Config.MissionTweaks = {
    -- prison_break = { cooldown = 1800, timeLimit = 720, disabledLocations = { 'North gate' } },
    -- gang_shootout = { peds = { 'g_m_y_lost_01' }, weapons = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL' } },
}

-- ============================================================================
--                               MISSION BUILDER
-- ============================================================================
-- Block setting ranges and defaults are in config/blocks.lua.
Config.Builder = {
    enabled = true,                            -- true = supervisors may use the Mission Builder (admins always can)
    maxHostiles = 40,                          -- armed NPCs per mission across all blocks, before scaling
    maxBlocks = 6,                             -- objective blocks in one custom mission at most
    minLocations = 1,                          -- locations a new custom mission needs before it can be published
                                               -- (more locations = it repeats less; 3 or more is a good habit)
    minLocationsOverride = 3,                  -- locations an edited built-in mission must keep before it can be
                                               -- published
    minLocationGap = 100.0,                    -- metres between locations of one mission
    minSpawnFromStart = 30.0,                  -- metres between any spawn point and the start point
    spawnMargin = 40.0,                        -- metres outside the start circle that armed NPCs of a new custom mission
                                               -- keep (shootout, boss, ambush and pursuit cars, door associates);
                                               -- files published before still load, with a warning
    maxPointFromStart = 300.0,                 -- metres a location's points may be outside its start circle: a
                                               -- point further away (left behind by a moved start) blocks
                                               -- publishing; routes, patrol checkpoints, escort ambush points and
                                               -- flee paths are exempt (50-2000)
    -- A builder's own bonuses and penalties: flat ones at most 50 points (points), percentage ones at most 25% of P
    -- (share, 0-1)
    bonusCap = { points = 50, share = 0.25 },
    requireTestToPublish = false,              -- true = supervisors may publish only a draft that passed a test
                                               -- (admins never need one); false = testing is optional for everyone
    supervisorItems = false,                   -- false = only admins may put items in a custom mission (items a run
                                               -- hands out can be used or sold before they are taken back); true =
                                               -- supervisors too
    useMyPosition = true,                      -- true = the Locations step has "Set start here" and "Add here":
                                               -- the point goes where you stand (or your vehicle is) and the tablet
                                               -- stays open; false = points are only placed with the aim tool
    autoFill = true,                           -- true = a spawn point row has "Fill N for me": the game proposes
                                               -- the points around the start, outside its keep-out, on safe ground
                                               -- (you keep them, try again or place them by hand); false = no button
    autoFillRing = { 15.0, 80.0 },             -- metres beyond the keep-out that "Fill N for me" puts points at
                                               -- (nearest, furthest)

    quickWizard = true,                        -- true = the New mission button opens a 4-step wizard (What,
                                               -- Where, Check, Publish): pick a template, stand at the spot, fill
                                               -- the points, publish; Open the full editor is on every step;
                                               -- false = the New mission dialog and the full editor only
    foldAdvanced = true,                       -- true = each block's settings show the few that matter
                                               -- (e.g. a shootout: waves, enemies per wave, weapons, difficulty)
                                               -- and fold the rest under "More settings"; false = every setting
                                               -- is shown open, as before

    -- On: a Teleport button next to each point on the Locations step puts you on the ground there (the server reads
    -- the saved point and logs it). Admins always; others only with Permissions.builderTeleport. Off: no button.
    teleport = true,

    -- built-in missions a new mission can start from: it copies their type, difficulty, team, times, bonuses,
    -- penalties and objectives, but none of their locations (you place your own). Empty = no templates
    templates = {
        'beat_patrol',
        'business_check',
        'parking_patrol',
        'pursuit_sim',
        'manhunt',
        'warrant_service',
        'gang_shootout',
        'hostage_rescue',
        'armored_truck_escort',
        'bomb_disposal',
    },
    testAtMaxTier = true, -- a test counts as passed only at the tier maxOfficers reaches
    editLockMinutes = 30, -- one editor at a time; renewed while they keep editing
    defaultTeam = { patrol = 2, training = 2, investigation = 2, tactical = 4 }, -- most officers a new mission
    -- starts with, by its type (the builder can change it on Details)
    autosaveSeconds = 30,
    exportPath = 'missions/custom/',           -- folder (inside missions/custom/) for missions made in the Builder.
                                               -- Another folder must be created by hand first, with archived,
                                               -- overrides, overrides/archived and deleted inside it (the server
                                               -- cannot create folders on Linux)
    keepBackups = true,                        -- keep <mission_id>.v<version>.lua.bak on every publish
    route = {                                  -- route recording (see Mission Builder, Route recording)
        snapEvery = 25.0,       -- metres between samples while recording
        maxOffRoad = 8.0,       -- samples further than this from a road node are rejected
        turnAngle = 30.0,       -- heading change (degrees) that keeps a waypoint
        maxGap = 150.0,         -- at least one waypoint this often, in metres
        minLength = 800.0,      -- metres a recorded route must be at least
        maxLength = 8000.0,     -- metres a recorded route may be at most
        minStartEndGap = 300.0, -- open routes: start and end at least this far apart
        loopClose = 50.0,       -- a race loop must end this close to its start
        undoMetres = 100.0,     -- Backspace removes this much of the recording
        testDriveTimeout = 30,  -- seconds to reach each waypoint in a test drive
        patrolSpacing = 300.0,  -- a patrol (checkpoint route) recorded by driving is saved as checkpoints about
                                -- this many metres apart along the drive, not as a road route
    },
    allowed = {                 -- the only models, weapons and animations builders can pick
        -- no automatic weapons: an NPC never gets one (Config.NpcCombat), so the Builder never offers one
        weapons = {
            'WEAPON_PISTOL',
            'WEAPON_COMBATPISTOL',
            'WEAPON_HEAVYPISTOL',
            'WEAPON_PUMPSHOTGUN',
        },
        -- base-game ped models only. The list holds every ped a built-in mission or a block default uses
        -- (inmates, the Kingpin, the escort driver), so a copy of any built-in mission can be published.
        peds = {
            'g_m_y_ballaeast_01',
            'g_m_y_famca_01',
            'g_m_y_mexgoon_01',
            'g_m_y_lost_01',
            'a_m_m_business_01',
            'a_f_y_business_01',
            's_m_y_prisoner_01',
            's_m_y_prismuscl_01',
            'g_m_m_armboss_01',
            's_m_m_armoured_01',
            'a_m_y_stbla_01',
            'a_m_m_eastsa_02',
            'a_m_y_mexthug_01',
            'a_f_y_eastsa_03',
            'a_m_m_salton_02',
            'g_m_y_salvagoon_01',
            'g_m_m_chicold_01',
        },
        -- base-game vehicle models a builder may give suspects and hostiles
        vehicles = {
            'sultan',
            'buffalo',
            'elegy2',
            'kuruma',
            'dominator',
            'asea',
            'primo',
            'emperor',
            'tornado',
            'stanier',
            'rancherxl',
            'bison',
        },
        escortVehicles = { 'stockade', 'stockade3' },  -- vehicle models an Escort mission may protect
        -- what a builder may have a person do at a point: clipboard, search, kneel, mechanic, notepad or photo
        animations = { 'clipboard', 'search', 'kneel', 'mechanic', 'notepad', 'photo' },
    },
    noBuildZones = {            -- no spawn point, marker or route waypoint inside these
        { label = 'Mission Row PD and FIB HQ', coords = vec3(470.63, -974.11, 30.18), radius = 120.0 },
        { label = 'Sandy Shores BCSO', coords = vec3(1833.06, 3679.32, 33.19), radius = 80.0 },
        { label = 'SASP HQ', coords = vec3(1560.38, 815.76, 76.21), radius = 80.0 },
        { label = 'Pillbox Hill Medical', coords = vec3(308.19, -595.35, 43.29), radius = 100.0 },
        { label = 'Paleto Bay Medical', coords = vec3(-254.54, 6331.78, 32.43), radius = 80.0 },
        -- the whole prison, every tower
        { label = 'Bolingbroke Penitentiary', coords = vec3(1691.5, 2578.5, 44.7), radius = 215.0 },
        { label = 'Fort Zancudo', coords = vec3(-2075.0, 3225.0, 33.0), radius = 320.0 },             -- the base: 4 circles
        { label = 'Fort Zancudo south-east', coords = vec3(-1875.0, 3050.0, 33.0), radius = 320.0 },
        { label = 'Fort Zancudo south-west', coords = vec3(-2300.0, 2950.0, 33.0), radius = 280.0 },
        { label = 'Fort Zancudo north-west', coords = vec3(-2250.0, 3300.0, 33.0), radius = 280.0 },
        -- live match boundary (up to 135 m) + push-back
        { label = 'Crimson-Arena Trailer Park', coords = vec3(2344.43, 2565.06, 46.67), radius = 160.0 },
        -- where arena players return after a match
        { label = 'Crimson-Arena lobby', coords = vec3(-282.01, -2030.46, 30.15), radius = 60.0 },
    },
}

-- ############################################################################
--                          PART 3 · PLAYER VS POLICE
-- Real players as suspects: the rules for every such case, live crimes and volunteer suspects.
-- Usually changed here: LiveCrime.enabled, Volunteers.enabled and CriminalTablet.enabled (all ship off), once your
-- server is ready for criminal players to take part.
-- ############################################################################

-- ============================================================================
--                    REAL SUSPECTS (rules for real players)
-- ============================================================================
-- Rules for every case where the suspect is a real player instead of an NPC: a LIVE crime (Config.LiveCrime) or a
-- mission played against a volunteer (Config.Volunteers). Nothing here does anything while both are off.
-- Crimson-Police never tells officers who a suspect is, and gives him nothing unless Config.FeatureRewards.suspect
-- is on (a volunteer paid for a fair case).
Config.RealSuspects = {
    -- The NPC-mission rules that do not fit a fight with a real player (each can be set back). 'normal' = an
    -- officer's own shots-fired, person-down and EMS calls go out like any officer's, so backup can come; 'silenced'
    -- = the NPC-mission rule (no alerts)
    officerAlerts = 'normal',
    -- 'first_contact' = an officer who gets near a suspect (contactRange) counts as arrived and his route check stops;
    -- 'start' = the NPC-mission rule (only the mission start counts)
    routeEnds = 'first_contact',
    -- 'keep_earned' = a downed officer leaves with what he earned so far and no type cooldown; 'failed' = the
    -- NPC-mission rule (his run is Failed)
    downed = 'keep_earned',
    -- Seconds down, with no EMS on duty, before the pick-up (keep equal to sc-ambulance's Config.DeathTime; NPC
    -- missions use Config.Downed.pickupDelay)
    downedPickupDelay = 400,
    -- false = no NPC-combat headshot protection or damage cut for officers once a real suspect is in the case; true =
    -- they keep Config.NpcCombat's officer settings
    npcCombat = false,
    -- Who can be a suspect:
    excludeAce = 'crimsonpolice.realsuspect.exclude',  -- players with this ace (server.cfg) are never suspects
    -- true = Crimson-Police admins (Config.AdminAce / Config.QboxAdmins) are never suspects either
    excludeAdmins = true,
    -- A character can't be a suspect within this many minutes of police duty, and can't take a case within this many
    -- minutes of being a suspect
    jobHopMinutes = 30,
    -- Seconds with no movement and no camera turn = AFK: never a suspect, and a suspect cuffed while AFK scores
    -- nothing
    afkSeconds = 300,
    afkSampleEvery = 15,             -- seconds between AFK samples (only suspects, volunteers and reported crews)
    noStartZones = {                 -- a player standing here can't become a suspect
        { label = 'Pillbox Hill Medical', coords = vec3(308.19, -595.35, 43.29), radius = 100.0 },
        { label = 'Paleto Bay Medical', coords = vec3(-254.54, 6331.78, 32.43), radius = 80.0 },
        { label = 'Crimson-Arena lobby', coords = vec3(-282.01, -2030.46, 30.15), radius = 60.0 },
        { label = 'Crimson-Arena Trailer Park', coords = vec3(2344.43, 2565.06, 46.67), radius = 160.0 },
    },
    contactRange = 100.0,            -- metres: an officer this close to a suspect has made contact
    -- When a suspect leaves (logs off, switches character, enters Crimson-Arena or another instance): 'void' = he
    -- counts for nobody; 'caught' = it counts as a detain for the officers; 'escaped' = it counts as getting away.
    -- Staff always get a note, and it never holds the officers' points
    onLeave = 'void',
    disconnectGrace = 120,           -- seconds a suspect who lost connection may come back and stay in the case
    reconnectNoticeMinutes = 30,     -- minutes: officers are told when a suspect who left cuffed is back this soon
    -- The staff note says "left soon after contact" when he left within this many seconds of it
    evadeWindow = 120,
    trail = {                        -- position trail kept for review
        every = 5,                   -- seconds between points
        max = 360,                   -- points kept per suspect
    },
    timelineMax = 300,               -- timeline entries kept per case
    -- Closed cases staff can still open in the Admin UI (their timeline, damage ledger and flags), the newest
    -- ones; open cases are always there
    casesKept = 16,
    -- true = the kept closed cases are saved (the database or the saves folder), so a restart keeps them (none older
    -- than pairLedgerDays); false = memory only, a restart starts the list again
    saveCases = true,
    -- true = admins (the antiFarmOverride key) get a Real suspects screen in the Admin UI while live crimes or
    -- volunteers are on: the cases, each case's timeline and damage ledger, pair statistics and the block, exclude
    -- and suspend tools; false = no screen (the cases are still kept)
    adminScreen = true,
    -- true = admins can lift a pair block, an exclusion or a suspension early from that screen (with a reason, in
    -- the audit log); false = each one runs to its end date
    staffLift = true,
    -- true = pair statistics, the running blocks and the case lists on that screen show character names next to
    -- citizen IDs (one name lookup per screen load); false = citizen IDs only
    staffNames = true,
    -- true = the damage ledger on that screen names the weapon (Combat Pistol); false = the raw weapon hash
    weaponNames = true,
    -- Proof the server checks before anything scores:
    cuffPairWindow = 10,             -- seconds between the officer's sc-police cuff and the suspect's cuffed state
    cuffRange = 3.5,                 -- metres between them at the cuff (sc-police allows 2.5; the rest is lag)
    custodyHoldSeconds = 30,         -- seconds the cuffs must hold before a detain counts
    -- An on-duty officer outside the case who cuffs a suspect: 'assist' = it counts as the case's cuff while an
    -- officer of the case is within contactRange of the suspect (else the suspect counts for nobody); 'stopped' = the
    -- suspect always counts for nobody, like a jail by someone outside the case
    outsideCuff = 'assist',
    -- Seconds: free this soon after the cuff = he won sc-police's cuff-break game (fair, once per case and not in
    -- the first 2 s); later, with no officer uncuff and no bobby pin, it is a self-uncuff: it counts as detained and
    -- staff get a note
    breakFreeSeconds = 20,
    -- Metres: a friend's successful bobby pin frees him with no note when that friend stood this close for 2 s or
    -- more (once per case)
    rescueRange = 4.0,
    neutralisedShare = 0.5,          -- a suspect cuffed while down (whoever downed him) counts this share of a detain
    jailRange = 6.0,                 -- metres between officer and suspect at the jail (sc-police allows 5)
    minJailTime = 5,                 -- a booking needs at least this sentence (sc-police counts months)
    jailTimeMax = 120,               -- longer sentences are recorded as this
    -- A booking counts only inside one of these ({} = anywhere): sc-police's station duty points and the prison;
    -- check them on your MLOs
    bookingZones = {
        { label = 'Mission Row PD', coords = vec3(470.63, -974.11, 30.18), radius = 120.0 },
        { label = 'Sandy Shores (BCSO)', coords = vec3(1833.06, 3679.32, 33.19), radius = 80.0 },
        { label = 'SASP', coords = vec3(1560.38, 815.76, 76.21), radius = 80.0 },
        { label = 'Bolingbroke Penitentiary', coords = vec3(1768.73, 2570.43, 44.73), radius = 180.0 },
    },
    -- Seconds after a hospital respawn he can't be detained for points (unless officers were with him when he
    -- went down)
    spawnProtectSeconds = 600,
    -- Seconds; keep equal to sc-ambulance's Config.DeathTime: a respawn sooner voids him and staff get a note
    earlyRespawnSeconds = 400,
    -- Officer conduct: these weapons are never a "shot" (a hit with one on a suspect who was never armed costs
    -- nothing)
    lessLethal = { 'WEAPON_STUNGUN', 'WEAPON_STUNGUN_MP', 'WEAPON_NIGHTSTICK', 'WEAPON_FLASHLIGHT' },
    armedMemory = 15,                -- seconds a suspect counts as armed after the server saw a gun in his hands
    downGrace = 3,                   -- seconds after he goes down before a hit counts as hitting a downed person
    damageLogMax = 200,              -- weapon hits between officers and suspects kept per case
    -- Anti-farm (admins only): nobody can take a case against one of his own characters or licenses, and the
    -- identifiers of both players are compared live, never stored or shown
    identityMatch = {
        block = { 'license', 'license2', 'discord', 'fivem', 'steam', 'xbl', 'live' }, -- same account = refused
        flag = { 'ip', 'token' }, -- same connection or PC = allowed but flagged (families share them)
    },
    -- One scored case of the same suspect per officer in this many hours (live crimes and volunteers together)
    pairCooldownHours = 24,
    maxCatchesPerSuspectDay = 2,     -- a suspect is worth points this many times a day, server-wide
    -- After a case, the same officers score nothing on that suspect for this many minutes
    suspectCooldownMinutes = 30,
    -- The same officer and suspect this often, with a second warning sign (a detain within fastCatchSeconds, a
    -- suspect never armed who moved under 30 m after contact, or a case under 3 minutes), flags that officer
    pairFlag = {
        count = 2,                   -- cases of the same pair (matched by license)
        days = 7,                    -- within this many days
    },
    fastCatchSeconds = 60,           -- seconds: a detain this soon after the case started is a warning sign
    pairLedgerDays = 30,             -- days the pair ledger keeps case rows (admin blocks stay until they expire)
    -- Surrender and Talk them down in a live case (Config.LiveCrime; nothing while live crimes are off). A suspect
    -- gives himself up with the command below, or says yes when an officer of the case close to him uses Talk them
    -- down (radial menu); the suspect always chooses. A surrendered suspect then detained with no officer hit on him
    -- scores the peaceful_arrest line (Config.Bonuses), and the case timeline shows who talked him down
    surrender = {
        enabled = true,              -- true = the surrender command and Talk them down work in live cases
        command = 'surrender',       -- the suspect's chat command (without the /)
        talkRange = 15.0,            -- metres: an officer this close to a free suspect can talk him down
        surrenderRange = 50.0,       -- metres: a surrender counts only with an officer of the case this close
        askSeconds = 20,             -- seconds the suspect's yes/no pop-up waits for an answer
        talkCooldown = 30,           -- seconds before the same officer can talk the same suspect down again
        holdSeconds = 120,           -- seconds a surrender lasts with no cuff before it lapses
        breakRange = 10.0,           -- metres: a surrendered suspect who moves this far from where he gave up ends it
    },
}

-- ============================================================================
--                            LIVE CRIMES (option A)
-- ============================================================================
-- A live crime is a real crime that Crimson-Contracts reports once its police alert goes out; the crew that started
-- the contract are the suspects. It shows as a red LIVE call on the Dispatch screen; officers who claim it respond
-- to the real crew and earn points for securing the scene, detaining and booking the suspects (the shares are the
-- live_* entries in Config.Bonuses). Crimson-Contracts needs ContractsConfig.LifecycleEvents = true.
Config.LiveCrime = {
    enabled = false,                 -- true = reported crimes become LIVE calls on the Dispatch screen
    -- false = officers on a live case may leave the GPS route to chase; true = the normal route rule
    -- (Config.Route.required)
    requireRoute = false,
    sources = { 'crimson-contracts' },  -- the only scripts allowed to report a crime
    types = {                           -- which crimes become LIVE calls, and the mission type whose points they use
        warehouse_burglary = 'investigation',
        container_heist = 'investigation',
        hostile_drug_pickup = 'tactical',
        drug_lab_raid = 'tactical',
        weapon_shipment = 'tactical',
        prisoner_ambush = 'tactical',
        atm_robbery = false,         -- false = never a LIVE call (a solo ATM hack has no crew to track)
    },
    suspectRadius = 300.0,           -- crew members further than this from the crime at the alert are not suspects
    offerTime = 300,                 -- seconds a LIVE call stays open before it lapses (the crime's end lapses it too)
    maxLiveRuns = 2,                 -- LIVE calls and live cases at once; a crime past this gets no LIVE call
    caseTime = 1800,                 -- seconds a live case lasts at most; it then ends with the points earned
    -- true = a unit of 2+ answers the ready check before its live case opens, like a mission; false = the case
    -- opens at once (a real crime does not wait)
    readyCheck = false,
    -- true = an officer with a type cooldown (he abandoned a mission of that type) can't claim a LIVE call of that
    -- type, and leaving a live case early starts that cooldown; false = live cases ignore type cooldowns
    typeCooldown = false,
    -- true = LIVE calls can still be claimed while a Cross-Department Mission runs (its lock stops missions only);
    -- false = the Cross-Department lock stops live cases too
    duringOperation = true,
    -- Backup: true = an on-duty officer on no mission who marks himself responding to the crime's own SC-Dispatch
    -- call, reaches the scene or cuffs a suspect gets a pop-up to join the live case; false = only the unit that
    -- claimed the LIVE call works the case
    backup = true,
    maxOfficers = 6,                 -- officers on one live case at most (the unit that claimed it counts)
    joinOfferSeconds = 30,           -- seconds the join pop-up waits for an answer
    -- The officers' tablet: true = a LIVE line on the unit's ready check and a case card on Active Mission (the
    -- three steps, the suspect count and when the "last reported" points were taken; never a suspect's state or a
    -- live position); false = the case shows like any mission
    caseCard = true,
    -- true = the result card lists each suspect's outcome by label (Suspect A: booked, Suspect B: got away) once the
    -- case is over; false = no outcomes on the result card
    resultOutcomes = true,
    -- Results for other scripts: true = when a live case ends, Crimson-Police sends the server-only event
    -- crimson-police:server:liveCrimeEnded (the crime, how the case ended and each suspect's outcome); false = no event
    endEvent = true,
    -- Who the export GetAvailablePolice counts: 'idle' = on-duty officers on no mission (they could answer a crime
    -- now); 'duty' = every on-duty officer. The export answers nil while enabled is false
    availablePolice = 'idle',
    -- The live case (officers who claimed a LIVE call): Respond, Secure the scene, then Detain and book the
    -- suspects. Metres around the reported place that count as being at the scene
    sceneRadius = 75.0,
    secureSeconds = 60,              -- seconds officers must hold the scene to secure it (0 = reaching it is enough)
    -- Seconds between the "last reported" map points of suspects still free (never a live position; 0 = no points)
    lastReportedEvery = 60,
    -- Seconds a case stays open once no suspect is left to work (all booked, lost, left or void) before it ends
    deadCaseSeconds = 30,
    -- Points of a live case: true = only its live lines (scene secured, each detain and booking x the suspect's
    -- share) and its conduct penalties; false = the mission type's points plus those lines, like a mission
    linesOnly = true,
    -- Which team sets a live case's tier (the points and cash multiplier of Config.Scaling): 'crew' = the number of
    -- suspects at the alert; 'officers' = the officers on the case, like a mission
    tier = 'crew',
    typeOfTheDay = false,            -- true = a live case of today's Type of the Day gets its points multiplier too
    goals = false,                   -- true = live cases count for the officers' daily and weekly goals
    challenge = false,               -- true = live cases count for the department challenge and the weekly bounty
    -- Money: true = a live case pays the officers cash like a mission of its type (its Config.MissionTypes payout,
    -- so the money is set already); false = points only. Ships off
    cash = false,
    items = false,                   -- true = a live case rolls the item rewards of its type too (Config.Rewards)
}

-- ============================================================================
--                     VOLUNTEER SUSPECTS (options B and C)
-- ============================================================================
-- A player who is not on police duty can volunteer, with the command below, to be the suspect of a police tablet
-- mission for an hour. When officers take a mission whose suspect a real player can play (Warrant Service's wanted
-- person, Street Race Bust's driver, Manhunt's fugitive) and a volunteer fits, he gets a yes/no pop-up; if he says
-- yes he plays that suspect instead of the NPC. Volunteers see pop-ups, notifications and a menu (or the criminal
-- tablet below, once it is on); they are paid only with Config.FeatureRewards.suspect on. Set a mode per mission
-- type below: while every mode is 'npc', nothing changes even with enabled = true.
Config.Volunteers = {
    enabled = false,                 -- true = players can volunteer with the command below
    -- The chat command (without the /) a player volunteers with: it asks him to agree to the rules and pick the
    -- suspects he will play, and while he volunteers it opens a menu to renew, change them or stop (restart to change)
    command = 'crimsonheat',
    windowMinutes = 60,              -- minutes a volunteer stays on the list; he can renew it from the menu
    -- A volunteer who says yes and then does not show up or walks away from the case gets a strike. This many
    -- strikes within strikeHours stop that player, on every character, from volunteering for blockHours
    strikes = 3,
    strikeHours = 24,                -- hours a strike counts towards the block
    blockHours = 24,                 -- hours a player who reached the strikes can't volunteer
    -- true = strikes and strike blocks are saved (the database or the saves folder), so a restart keeps them; false =
    -- memory only, a restart clears them. The volunteer list is never saved: after a restart a player volunteers again
    saveStrikes = true,
    -- true = admins can clear a player's strikes and strike block from the Real suspects Volunteers tab (with a
    -- reason, in the audit log); false = they run out on their own
    staffClearStrikes = true,
    -- Who plays the suspect of a mission a volunteer can play, per mission type: 'npc' = always the NPC (as today);
    -- 'players_when_available' = when the unit ticks "Real suspect OK" on the Mission Board and a volunteer who
    -- fits is online, he is asked to play the suspect, else the NPC plays him; 'players_only' = the type's missions
    -- are offered only while a volunteer who fits is free, to a unit that ticks "Real suspect OK", and its draw
    -- takes only missions a volunteer can play. A mission named in missionModes below follows its own mode instead
    modes = {
        patrol = 'npc',
        training = 'npc',
        investigation = 'npc',
        tactical = 'npc',
    },
    -- The same choice for single missions, by mission id (beats its type's mode), e.g. { warrant_service =
    -- 'players_only' }. Empty = every mission follows its type
    missionModes = {},
    -- Asking: the volunteers who fit get a yes/no pop-up one at a time (the one a 'players_only' accept held first).
    -- A no or no answer is never a strike
    askSeconds = 30,                 -- seconds the pop-up waits for an answer before the next volunteer is asked
    askTries = 3,                    -- volunteers asked per mission before the NPC plays the suspect
    -- After a yes he has this many seconds to reach the suspect's starting point (it is set as his map waypoint); not
    -- there in time = a no-show (a strike) unless officers already reached him
    travelSeconds = 300,
    meetRadius = 25.0,               -- metres from the starting point that count as being in position
    -- Seconds after his yes in which his own Cancel this case is no strike (once officers reached him it always is)
    cancelGraceSeconds = 60,
    -- When the volunteer who said yes drops out before officers reach him (no-show, Cancel this case, logs off):
    -- 'npc' = the NPC plays the suspect as if nobody had said yes; 'end' = the mission ends (see voidRun). A
    -- 'players_only' mission, and any mission once officers reached him, always ends
    onVoid = 'npc',
    -- How such a mission ends: 'cancelled' = Abandoned with no cooldown, penalty or pay; 'keep_earned' = Completed
    -- with what the officers earned so far (the points of their lines only: no base points, end-of-run bonuses or
    -- mission cash)
    voidRun = 'cancelled',
    -- A volunteer who is caught while AFK (he did not move for a while, Config.RealSuspects): true = his part is
    -- void (a strike, and the mission ends as in voidRun); false = the catch counts like any other catch
    afkCatchVoids = true,
    -- Warrant Service's armed associates while a volunteer plays the wanted person at the door: false = they stay
    -- away (the NPCs would shoot him too); true = they come out at the knock as usual
    doorAssociates = false,
    -- Street Race Bust's other NPC racers (and the other suspect cars of a stop pursuit) while a volunteer drives one
    -- in his own car: false = his car is the only suspect car; true = the others still come (he takes one car's place)
    driverNpcCars = false,
    -- Seconds between the map's "last reported" points of a volunteer driver once he is in position (where the server
    -- last saw him, never a live position); 0 = no points, the map keeps the starting point
    driverReportEvery = 30,
    -- Manhunt's other NPC fugitives (more officers bring more) while a volunteer hides as one of them: false = he is
    -- the only fugitive; true = the others still hide (he takes one fugitive's place)
    fugitiveNpcs = false,
    -- Seconds a volunteer fugitive may stay outside the search circle (the red circle on his own map; it shrinks
    -- towards where the server last saw him at each clue) before his part is void (a strike); 0 = no circle rule
    fugitiveOutSeconds = 30,
    -- Results for other scripts: true = when a mission a volunteer said yes to ends, Crimson-Police sends the
    -- server-only event crimson-police:server:volunteerEnded (the mission, the suspect he played, how it ended and
    -- his outcome, by his citizenid; another script can reward him); false = no event
    endEvent = true,
    -- What a mission played against a volunteer (once he said yes) takes part in; true = like any other mission
    typeOfTheDay = false,            -- true = today's Type of the Day points multiplier applies to it too
    goals = false,                   -- true = it counts for the officers' daily and weekly goals
    challenge = false,               -- true = it counts for the department challenge and the weekly bounty
    -- Money: true = it pays the officers cash like any mission of its type (its Config.MissionTypes payout, so the
    -- money is set already); false = points only (its cash is 0). Ships off. The volunteer's own pay is
    -- Config.FeatureRewards.suspect
    payCash = false,
    payRewards = false,              -- true = it rolls the item rewards of its type too (Config.Rewards)
}

-- ============================================================================
--                               CRIMINAL TABLET
-- ============================================================================
-- A tablet of its own for players who play real suspects, with a dark street look (nothing like the police
-- tablet): Home (volunteer on or off, the hour window), Jobs (the suspect police want played right now: the mission
-- type, the suspect, the area; Accept is the same yes as the pop-up), Active (the meet point, the rules and the
-- time left, give up), History (cases since the last restart, outcomes and strikes with when they run out) and
-- Rules. It runs on Volunteer suspects above (Config.Volunteers.enabled must be on too) and never shows where an
-- officer is. Police on duty can never open it.
Config.CriminalTablet = {
    enabled = false,                 -- true = players can open the criminal tablet with the command or item below
    command = 'crimtab',             -- the chat command (without the /) that opens it (restart to change)
    -- An ox_inventory item name that also opens it (items/ox_inventory_items.lua has an entry to paste), or false
    item = false,
    -- Who may use it: 'everyone' = every player whose job is not a police job (Config.Departments); 'granted' =
    -- only the players named by the criminalTablet extra grant (Admin UI -> Permissions -> Extra grants)
    access = 'everyone',
    -- true = the volunteer command (Config.Volunteers.command) opens this tablet for a player who may use it,
    -- instead of the pop-up menu; false = the command keeps its menu
    replaceCommand = false,
    historySize = 20,                -- past cases each player's History keeps (memory only: a restart clears it)
}

-- ############################################################################
--                           PART 4 · POLICE TEAMWORK
-- Officers working together: units, Cross-Department Missions, supervisor mission controls, field
-- training, leaderboards, the department challenge and officer profiles.
-- Usually changed here: the unit size, which Mission controls supervisors get, and field training.
-- ############################################################################

-- ============================================================================
--                                    UNITS
-- ============================================================================

Config.Units = {
    invitePolicy = 'anyone',            -- 'anyone' (every member may invite) | 'leader'
    readyCheck = true,                  -- units of 2+ confirm before the draw
    readyTimeout = 20,                  -- seconds to answer
    kickReinvite = 60,                  -- seconds before a kicked officer can be invited again
    nearbyBands = { 250, 1000, 3000 },  -- metres: distance bands in the invite list
}

-- ============================================================================
--                          CROSS-DEPARTMENT MISSIONS
-- ============================================================================

Config.CrossDept = {
    enabled = true,          -- true = officers may launch cross-department missions
    minParticipants = 2,     -- officers a cross-department run needs to start
    maxParticipants = 8,     -- officers one cross-department run takes at most
    joinWindow = 300,        -- seconds until joining closes (or the launcher taps Start now)
    idleCancel = 1800,       -- auto-cancel after this long with no run in progress
    cooldown = 1800,         -- seconds between launches, server-wide
    waitlist = true,         -- officers can queue when every place is taken; a freed place goes to the first
}

-- ============================================================================
--                               MISSION CONTROLS
-- ============================================================================
-- See also Part 2 (NPC missions): these controls change the NPC missions of one department.

-- Rules a department's supervisors may change for their own department from the Supervisor UI, only inside the
-- bounds set here and only while an admin switched them on: Config.Permissions.supervisor.missionControls and the
-- control's own on. A department may have its own bounds (Config.Departments.<key>.missionControls = { <control> =
-- { on, min, max } }); they win over the ones below for it. Every change needs a reason and is in the audit log.
-- The cooldown controls are server-wide (one value for every department), outside the master switch and ship
-- on: a supervisor may change them out of the box; until one does, every cooldown stays as config.lua sets it.
-- Clearing one officer's cooldown is a cooldown control too (server-wide, ships on). Every other control ships off.
Config.MissionControls = {
    changeWait = 300,   -- seconds between two changes of one control in one department
    selfExempt = true,  -- a control that relaxes a rule never applies to the supervisor who set it or a unit he is in
    grants = {},        -- per department who may use them, e.g. { sast = { minGrade = 4 } }; {} = every supervisor
    controls = {        -- per control: on = the admin switch, min/max = the only values a supervisor may pick
        -- x every mission's cooldown, per mission type, for every department; min 0 = a type with no mission cooldown
        cooldownScale = { on = true, min = 0, max = 2 },
        -- the abandon cooldown in seconds (Limits.abandonCooldown) for every department; 0 = none
        abandonCooldown = { on = true, min = 0, max = 900 },
        -- false switches the no-repeat rule (Draw.avoidLast) off for every department: a mission may come up twice
        noRepeat = { on = true },
        -- completed missions per officer per hour (Limits.maxCompletionsHour) for every department
        hourlyCap = { on = true, min = 1, max = 16 },
        -- completed missions per officer per day (Limits.maxCompletionsDay) for every department; 0 = no cap
        dailyCap = { on = true, min = 0, max = 40 },
        -- happy hour minutes: no mission cooldowns for anyone on the server (abandon cooldown and caps stay)
        happyHour = { on = true, min = 5, max = 30 },
        -- Department Report: a supervisor clears one officer's mission or type cooldown (any department, never his
        -- own character, never while the officer is on a run); each officer still at most
        -- AdminControl.cooldownClearsPerDay clears a day by all staff together
        clearCooldown = { on = true },
        -- Live Missions: a supervisor adds min to max minutes per click to a running mission of his department
        -- (never his own); the time limit the fast-finish bonus is judged on stays the same
        addRunTime = { on = false, min = 1, max = 5 },
        -- seconds a unit of his department has to reach the start after accepting (Limits.startTimeout and the
        -- mission's own); read when the run is accepted, so a change never moves a run already going
        startTimeout = { on = false, min = 300, max = 900 },
        -- seconds a unit of his department has to answer the ready check (Units.readyTimeout); 0 switches the ready
        -- check off for his department, allowed only while canTurnOff = true
        readyCheck = { on = false, min = 10, max = 40, canTurnOff = false },
        -- x the mission's time limit for runs of his department; the fast-finish bonus still uses the unscaled limit
        timeLimit = { on = false, min = 1.0, max = 1.25 },
        -- seconds after a run of his department starts before officers who never reached the start are removed
        -- (AntiCheat.idleCheck); stricter only: never more than that config value
        idleCheck = { on = false, min = 60, max = 180 },
        -- how hard mission NPCs are on runs his department leads: one of the presets listed here
        -- (NpcDifficulty.presets: easy, normal, hard, custom); read when the run is accepted; NpcCombat's limits
        -- still apply on top, and points and cash never change
        difficulty = { on = false, presets = { 'easy', 'normal' } },
        -- the largest unit an officer of his department may lead (invites, joins and accepting a mission); never
        -- above Limits.maxUnitSize
        unitSize = { on = false, min = 2, max = 4 },
        -- Mission Board: mission types (or single missions) a supervisor switches off for his department; its
        -- officers see the type locked, other departments still take it; it stays until switched back on
        types = { on = false },
        -- Mission Board: one mission type shown to his department's officers as "Recommended by command", right
        -- after their favourites; points and pay never change
        featuredType = { on = false },
        -- Department Report: a supervisor bars one officer of his department (a lower grade, never himself) from
        -- taking missions for min to max hours, with a reason: no Mission Board accept, mission call claim or
        -- Cross-Department join; the tablet stays usable and a mission already running goes on. The one who set it
        -- and admins (Officers -> Today & cooldowns) may lift it early
        missionBan = { on = false, min = 1, max = 24 },
        -- Dispatch: his department's own lane of mission calls next to the server's: min to max seconds between two
        -- lane calls (he picks a range inside it), how many may be open at once (up to callLaneMaxOpen), the areas
        -- and the mission types (MissionCalls.types) with a weight each; only his department sees and claims them
        callLane = { on = false, min = 120, max = 600 },
        -- seconds a supervisor of his department waits between two mission calls he creates
        -- (MissionCalls.staffCooldown); the one who shortens it keeps the config wait for himself
        staffCallWait = { on = false, min = 60, max = 120 },
        -- Supervisor UI: a supervisor posts a short notice (up to noticeMaxLength characters, 1 to 30 days) for his
        -- own department only; its officers see it on Home -> Announcements, other departments never do. At most 5
        -- run at once per department, the banned-word list applies, and every post and end is audited
        notices = { on = false },
        -- Cross-Department Missions: a supervisor keeps his department's officers out of them (they cannot join)
        -- or caps how many of them may take part in one; every board still shows only the running operation and
        -- the wait between launches stays server-wide
        crossDept = { on = false },
        -- Leaderboard: whether other departments see his department's officers by name or by callsign only, and
        -- which Rank by tabs his department's officers see (Leaderboard.metrics; points always). Presentation only:
        -- counts, the Department Challenge and the admin boards never change
        boards = { on = false },
        -- Review: stricter rules for his department's flagged runs: a supervisor's Void waits for a second
        -- supervisor of the department, and flags of the kinds he picks go to admins only. Admins are never bound
        -- and the anti-cheat flag triggers stay as they are
        reviewRules = { on = false },
        -- Mission Board and mission call claims: which of the twists enabled in Events.twists his department's
        -- leaders are offered at the accept step, and which of them start ticked; a twist his department does not
        -- offer is refused. The twists' bonuses never change
        twists = { on = false },
        -- Happy hour cash: x the cash of a completed run his department leads that was accepted while a happy hour
        -- ran (kept for the run, so the end of the hour never cuts it); never on test runs, Cross-Department runs or
        -- the Weekly Boss, and Cash.dailyCap still applies. min = max = 1.0 moves nothing: raise max (e.g. 1.25)
        happyHourCash = { on = false, min = 1.0, max = 1.0 },
        -- Twist cash: x each twist's cash (Events.twists) on runs his department leads, read at the accept; the chosen
        -- twists together still stop at Events.twistMaxCash and points never change. min = max = 1.0 moves nothing
        twistCash = { on = false, min = 1.0, max = 1.0 },
        -- Happy hour points: x the final points of a completed run his department leads that was accepted while a
        -- happy hour ran (kept for the run); never for the one who started the hour, on test runs, Cross-Department
        -- runs or the Weekly Boss. min = max = 1.0 moves nothing: raise max (e.g. 1.25)
        happyHourPoints = { on = false, min = 1.0, max = 1.0 },
        -- Twist points: x each twist's points share (Events.twists) on runs his department leads, read at the accept;
        -- the chosen twists together still stop at Events.twistMaxPoints. min = max = 1.0 moves nothing
        twistPoints = { on = false, min = 1.0, max = 1.0 },
        -- Type of the Day: a supervisor picks one mission type for TOMORROW, at most once a day for his department;
        -- tomorrow his department's officers earn the Type of the Day points (Events.todMultiplier) on that type
        -- instead of the server's type, other departments keep the server's. Never on his own runs or a unit he is in
        typeOfTheDay = { on = false },
        -- Dispatch: a supervisor pages a unit of his department (never his own) with one mission he chooses instead
        -- of a random one; only that unit sees the mission's name and may accept or decline it, every accept rule
        -- stays (cooldowns, caps, unit size), the call never earns rapid response and the audit names the mission
        pushMission = { on = false },
        -- Goals: a supervisor picks min to max of your daily goals and of your weekly goals (Goals.daily, Goals.weekly)
        -- his department's officers draw theirs from, starting at the next weekly reset (none picked = every goal);
        -- the goals' points never change and the supervisor himself keeps your whole lists
        goals = { on = false, min = 1, max = 5 },
        -- Department Report: a supervisor gives min to max points at a time to an officer of his own department
        -- (never to himself or another character of his license), with a reason, through the same logged manual award
        -- as Admin UI -> Give or take points (AdminControl.pointAdjust off stops it too); shown in the officer's history
        -- like an admin's award, at most awardPointsPerDay points a supervisor a day
        awardPoints = { on = false, min = 1, max = 50 },
    },
    happyHourPerDay = 1, -- happy hours a day server-wide (any supervisor; admins any); never for the one who started it

    -- officers' cooldowns one supervisor may clear a day (admins any)
    clearCooldownPerDay = 5,
    -- times one supervisor may add minutes to a running mission a day (admins any)
    addRunTimePerDay = 10,
    -- seconds supervisors may add to one running mission in all, counted together with an admin's additions and
    -- never above AdminControl.runTimeAddMax
    addRunTimeMax = 300,
    -- mission bans one supervisor may set a day (admins any)
    missionBanPerDay = 3,
    -- calls one department's lane may have open at once (every open call still counts against MissionCalls.maxOpen)
    callLaneMaxOpen = 2,
    -- characters a department notice may hold (at most 280, the length of an admin's staff notice)
    noticeMaxLength = 280,
    -- department notices one supervisor may post a day (admins any)
    noticesPerDay = 5,
    -- missions one supervisor may push to a unit a day (the pushMission control; admins any)
    pushMissionPerDay = 5,
    -- points one supervisor may give a day in all (the awardPoints control; admins any); 0 = no limit
    awardPointsPerDay = 100,
}

-- ============================================================================
--                                FIELD TRAINING
-- ============================================================================
-- Field training (FTO): a supervisor (or an admin) pairs a trainer with a rookie of his own department in Supervisor
-- UI -> Department Report. Completed missions the rookie runs together with his trainer (both finish the same run)
-- count towards the sign-off tasks below. Once a task's count is reached the trainer signs it off on his tablet
-- (Profile -> Field training), with an optional note. When every task is signed off the rookie gets the badge below
-- and the training is done. Every pairing and sign-off is in the audit log. Off when you install.
Config.FieldTraining = {
    enabled = false,                 -- true = supervisors can pair trainers and rookies, and runs count for them
    -- Who may train, per department key: the lowest Qbox grade number of a trainer (that grade and up). A department
    -- not listed here uses its supervisorGrade (so only supervisors train there)
    trainerGrades = { sast = 2, fib = 2 },
    -- Sign-off tasks, per mission type key: the completed missions of that type the rookie must run with his trainer
    -- before the trainer may sign the task off. A type left out (or 0) is no task
    tasks = { patrol = 3, investigation = 2, tactical = 1 },
    rookiesPerTrainer = 2,           -- rookies one trainer may train at the same time
    badge = 'field_training',        -- the badge a rookie gets when every task is signed off (Profile -> Badges)
    -- Ride-along rule: mission type keys (e.g. { 'tactical' }) a rookie in training may only accept (or claim) with his
    -- trainer in the same unit. Empty = a rookie runs every type with anyone
    requireTrainerFor = {},
    trainerBonus = 0,                -- points the trainer gets for each task he signs off (0 = none)
}

-- ============================================================================
--                                 LEADERBOARD
-- ============================================================================

Config.Leaderboard = {
    cacheSeconds = 60,       -- seconds a board is reused before it is counted again
    minRunsToRank = 3,       -- runs in the window an officer needs to be ranked
    topN = 25,               -- rows a board shows
    weekStartsOn = 'monday',
    seasonWeeks = 8,         -- suggested season length for "weeks left"; an admin ends the season
    -- Rank by tabs; 'live_catches' (suspects detained in live cases, Config.LiveCrime) can be added
    metrics = { 'points', 'missions', 'arrests', 'impounds', 'citations', 'rescues', 'calls', 'judgement' },
    minDecisions = 10,       -- Judgement: decisions needed in the window
    weeklyBadges = {},       -- extra weekly badges by metric, e.g. { 'arrests' }; Officer of the Week stays by points
    announceWeekly = true,   -- the weekly top 3 on Home and the board webhook
    announceMonthly = true,  -- the monthly top 3 on Home and the board webhook
}

-- ============================================================================
--                             DEPARTMENT CHALLENGE
-- ============================================================================

Config.Challenge = {
    enabled = true,            -- true = departments compete in seasons (the department challenge)
    scoring = 'average',       -- 'average' (per active officer) | 'total' | 'top10'
    minRunsActive = 3,         -- runs in the week that make an officer active (the average counts only these)
    weeklyBounty = true,       -- true = a weekly bounty is picked every week
    bountyBonus = 0.10,        -- share of its week's challenge points the bounty winner gets on top (0.10 = +10%)
    bounties = {               -- one is picked at random each week; counted per active officer
        { id = 'most_tactical', label = 'Most Tactical missions' },
        { id = 'most_cross', label = 'Most cross-department runs' },
        { id = 'most_unit', label = 'Most unit runs' },
        { id = 'most_completed', label = 'Most completed runs' },
        { id = 'most_arrests', label = 'Most arrests' },
        { id = 'most_calls', label = 'Most mission calls answered' },
    },
}

-- ============================================================================
--                               OFFICER PROFILE
-- ============================================================================

Config.Profile = {
    bioMax = 280,                                 -- characters
    bioLines = 3,                                 -- lines a bio may have at most
    editCooldown = 300,                           -- seconds between profile changes
    bannedWords = {},                             -- extra words refused in bios (any case, whole words)
    bannedWordsFile = 'config/banned_words.txt',  -- the shipped default list; false = none
    bioRequiresApproval = false,                  -- true = a new bio is Pending until a supervisor or admin approves it
    reports = { perDay = 3, reasonMax = 140 },    -- Report profile: per reporter per day; text length
    avatarPresets = {                             -- image files ship in the UI; level = unlocked at that level
        { id = 'shield' },
        { id = 'star' },
        { id = 'badge' },
        { id = 'dept' },             -- the department logo
        { id = 'k9', level = 5 },
        { id = 'motor', level = 10 },
        { id = 'heli', level = 20 },
        { id = 'swat', level = 30 },
        { id = 'detective', level = 40 },
    },
    avatarUrls = {
        enabled = false,             -- allow image links as profile pictures
        requireApproval = true,      -- a supervisor of the department or an admin approves each new link
        perDay = 3,                  -- link submissions per officer per day
        -- exact host names allowed. Not cdn.discordapp.com: its links carry signed query strings and
        -- expire. i.imgur.com is blocked in some regions (including the UK).
        hosts = { 'r2.fivemanage.com', 'i.imgur.com' },
    },
    -- accessibility looks worked out from the department theme
    appearances = { 'department', 'midnight', 'high_contrast', 'colourblind' },
    uiScale = { 0.85, 1.25, 1.0 },   -- min, max and default tablet size
    showMdtCommendations = false,    -- also show SC-Dispatch MDT commendations, read-only
}

-- Officer options: the choices each officer makes for their own tablet on the My options screen, saved per
-- character. A department may set its own allow, defaults and bounds (Config.Departments.<key>.officerOptions =
-- { allow = {}, defaults = {}, bounds = {} }); they win over the ones below for its officers.
Config.OfficerOptions = {
    enabled = true,                  -- false = no My options screen; every option keeps its default for everyone
    allow = {                        -- per option: false = officers cannot change it, everyone gets the default
        hudSide = true,              -- the mission HUD on the right or the left of the screen (kept on this PC)
        hudScale = true,             -- the mission HUD bigger or smaller (kept on this PC)
        hudCompact = true,           -- the mission HUD shows only the current objective (kept on this PC)
        reduceMotion = true,         -- no slide-in or flashing on the HUD and the toasts (kept on this PC)
        hudLook = true,              -- the officer's tablet look on the HUD, result card and toasts (this character)
        textSize = true,             -- larger text on the tablet and the mission HUD (this character)
        toastTime = true,            -- how long notifications stay on screen (kept on this PC)
        resultTime = true,           -- how long the mission result card stays on screen (kept on this PC)
        quietRun = true,             -- fewer pop-ups during a mission: social news goes to the bell (kept on this PC)
        keyHints = true,             -- the ready check, a new call and the contact HUD line name their key (this PC)
        soundCalls = true,           -- the tone of a new mission call (kept on this PC)
        soundUnit = true,            -- the tone of a unit invite and a ready check (kept on this PC)
        soundCues = true,            -- the objective cues on a run: checkpoints, a defused target (kept on this PC)
        favouriteTypes = true,       -- the mission types shown first on the Mission Board (this character)
        hiddenTypes = true,          -- the mission types folded away on the Mission Board (this character)
        skipAcceptConfirm = true,    -- accept a mission type in one click, without the confirm (this character)
        usualTwists = true,          -- the twists already ticked when the officer takes a mission (this character)
        skipClaimConfirm = true,     -- claim a mission call in one click, without the confirm (this character)
        callAlerts = true,           -- which new mission calls pop up: every call or favourite types (this character)
        dispatchKeyAfterCall = true, -- the tablet key opens Dispatch just after a mission call (this character)
        openOn = true,               -- the screen the tablet opens on (this character)
        rememberFilters = true,      -- Dispatch and the Leaderboard keep their filters (kept on this PC)
        abandonConfirm = true,       -- Abandon asks in a dialog; off = press it twice (this character)
        skipRecalcConfirm = true,    -- recalculate the route in one click, without the confirm (this character)
        distanceUnits = true,        -- distances in metres or in miles (kept on this PC)
        autoReady = false,           -- answers the unit ready check for the officer: off unless you want it
        objectiveGps = true,         -- how the map leads to each objective: line, waypoint or none (this character)
        hudTargetLine = true,        -- the HUD line naming the objective and how far it is (kept on this PC)
        colourblindMap = true,       -- colour-blind colours for objective blips, no red or green (kept on this PC)
    },
    defaults = {                     -- per option: what every officer starts with
        hudSide = 'right',           -- 'right' (as before) or 'left': the side of the screen the mission HUD sits on
        hudScale = 1.0,              -- size of the mission HUD on top of the screen size (1.0 = as before)
        hudCompact = false,          -- true = the HUD shows the current objective, the done count and the timer
                                     -- only; false = every objective (as before)
        reduceMotion = false,        -- true = the HUD and the toasts appear without sliding in or flashing
        hudLook = false,             -- true = the HUD, result card and toasts use the officer's tablet look
                                     -- (appearance and accent); false = the department theme (as before)
        textSize = 'normal',         -- 'normal' (as before) or 'large': text size on the tablet and the mission HUD
        toastTime = 'normal',        -- how long notifications stay: 'short' (3 s, warnings 5 s), 'normal' (5 s,
                                     -- warnings 7 s, as before) or 'long' (8 s, warnings 12 s)
        resultTime = 25,             -- seconds the mission result card stays on screen (25 = as before)
        quietRun = false,            -- true = during a mission, unit invites, commendations, rewards and profile news
                                     -- go only to the bell; false = they pop up as before
        keyHints = true,             -- true = the ready check banner says "or press K", a new mission call names the
                                     -- Dispatch key and the contact HUD line its key (an unbound key is never named);
                                     -- false = no key hints (as before)
        soundCalls = true,           -- true = a new mission call plays its tone (as before); false = no tone
        soundUnit = true,            -- true = a unit invite and a ready check play a tone (as before); false = none
        soundCues = true,            -- true = a checkpoint, defused target or found item plays a cue (as before)
        favouriteTypes = {},         -- mission type keys shown first on the Mission Board, e.g. { 'tactical' }; {} = the
                                     -- board's own order (as before)
        hiddenTypes = {},            -- mission type keys folded under "Hidden types" on the Mission Board; never every
                                     -- type; {} = none (as before)
        skipAcceptConfirm = false,   -- true = Accept starts a type at once, the warnings sit under the cards; false =
                                     -- Accept asks first (as before)
        usualTwists = {},            -- twist keys ticked at the start of the accept step (Mission Board, mission call
                                     -- claim) where that card offers them, e.g. { 'time_crunch' }; the officer can
                                     -- untick them. Any = they replace the department's pre-ticked twists; {} = the
                                     -- department's pre-ticked twists, else none (as before)
        skipClaimConfirm = false,    -- true = Claim on a mission call takes it at once (the nearest unit still wins a
                                     -- claim together); false = Claim asks first (as before)
        callAlerts = 'all',          -- 'all' = every new mission call pops up (as before); 'favourites' = only calls
                                     -- of the officer's favourite types, the rest still show on Dispatch
        dispatchKeyAfterCall = false, -- true = for 20 s after a mission call pops up, the tablet key opens Dispatch
        -- (nothing is claimed); false = it opens as usual (as before)
        openOn = 'last',             -- the screen the tablet opens on: 'last' (the screen it was closed on, as before),
                                     -- 'home' or 'active_on_run' (Active Mission on a run, Unit in a ready check)
        rememberFilters = false,     -- true = Dispatch and the Leaderboard open with the filters used last on this
                                     -- PC; false = their own defaults (as before)
        abandonConfirm = true,       -- true = Abandon asks in a dialog (as before); false = no dialog: the button turns
                                     -- into "Click again to abandon" for 3 s, so it still takes two presses
        skipRecalcConfirm = false,   -- true = Recalculate route works at once (Config.Route.maxRecalcs still counts);
                                     -- false = it asks first (as before)
        distanceUnits = 'metric',    -- 'metric' (m and km, as before) or 'imperial' (ft and miles) on the HUD, Active
                                     -- Mission and Dispatch
        autoReady = false,           -- true = the officer is Ready at once when the unit leader accepts a mission type,
                                     -- if they are at the keys and near the leader; false = they answer (as before)
        objectiveGps = 'route',      -- 'route' = a GPS line to each objective (as before); 'waypoint' = a map waypoint
                                     -- set on each new objective instead; 'off' = none (the Objective GPS button
                                     -- still sets one). Radio Silence still hides it; the drive to the start keeps
                                     -- its own line
        hudTargetLine = true,        -- true = the HUD names the objective and how far it is (as before); false = no
                                     -- such line
        colourblindMap = false,      -- true = objective blips and lines use blue, yellow, orange, white and purple,
                                     -- never red or green; false = Config.Markers.kinds colours (as before)
    },
    bounds = {                       -- per number option: { min, max } officers may pick
        hudScale = { 0.8, 1.3 },     -- smallest and biggest mission HUD size an officer may pick
        resultTime = { 8, 60 },      -- shortest and longest time (seconds) an officer may keep the result card
    },
    autoReadyRange = 150.0,          -- metres: Auto-Ready answers only while the officer is this close to the leader
}

Config.Commendations = {
    enabled = true,                  -- true = supervisors may commend officers
    -- the kinds a supervisor may pick (ids: rename them in Admin UI -> Settings -> Names, profile.commend.kind.<id>)
    kinds = { 'valor', 'lifesaving', 'teamwork', 'professionalism', 'leadership', 'investigation' },
    citation = { 10, 255 },          -- characters
    perSupervisorPerDay = 3,         -- commendations one supervisor may give per day
    sameKindCooldownDays = 7,        -- same officer, same kind
    crossDepartment = false,         -- true = supervisors may commend officers of other departments
    announceDays = 7,                -- days the Home announcement shows for the recipient
    announce = false,                -- also post it to the board webhook
}

-- ############################################################################
--                         PART 5 · ECONOMY AND REWARDS
-- Cash, payout changes, disputes, points, XP, badges, goals, bonuses and item rewards.
-- Usually changed here: Cash (bank or cash, server or society money, the daily cap), bonus values and goals.
-- Item rewards, feature rewards and the money tools all ship off.
-- ############################################################################

-- ============================================================================
--                                     CASH
-- ============================================================================

Config.Cash = {
    account = 'bank',     -- 'bank' or 'cash'
    source = 'server',    -- 'server' (new money) or 'society' (the department's Renewed-Banking account)
    minPayout = 0,        -- limits for any base payout set in-game
    maxPayout = 25000,    -- dollars
    dailyCap = 0,         -- max cash per officer per day; 0 = no cap
    -- Money tools outside the normal flow (Admin UI → Payments, Departments). All ship off: turning one on in
    -- Settings needs the typed word ENABLE and is audited.
    allowUnfundedRetry = false,  -- retry payments the department account could not cover
    allowCapTopUp = false,       -- pay the part of a payment the daily cap cut
    allowPayAgain = false,       -- pay a payment stuck in 'paying' again (after checking the bank history)
    restoreForfeited = false,    -- a restored run pays its forfeited cash after all
    allowAddFunds = false,       -- add money to a department's account
    addFundsMax = 50000,         -- dollars per Add funds
    allowClawback = false,       -- take back cash already paid
    allowManualCash = false,     -- pay an officer by hand
    manualDailyLimit = 10000,    -- dollars one admin may pay by hand per day
    lowBalanceWarn = 0,          -- warn below this department balance (0 = off)
}

-- ============================================================================
--                                PAYOUT EDITING
-- ============================================================================

Config.Payouts = {
    supervisorRange = { 0.5, 2.0 },   -- supervisors: 50%–200% of the type's payout in Config.MissionTypes
    supervisorCooldown = 1800,        -- seconds between changes to the same type (any supervisor)
    requireReason = true,             -- a reason is required for every payout change
}

-- ============================================================================
--                                   DISPUTES
-- ============================================================================

Config.Disputes = {
    windowHours = 48,   -- hours after a run that its officers may dispute it
}

-- ============================================================================
--                         SCORING, XP LEVELS AND GOALS
-- ============================================================================

-- How a run's points (P = the mission type's points) are worked out. Usually changed here: the streak and the common
-- bonuses and penalties below.
Config.Scoring = {
    scoreCap = 2.0,          -- × P
    streakStep = 0.05,       -- × points added per day of streak (0.05 = +5% a day)
    streakMax = 0.25,        -- the streak adds at most this (0.25 = +25%)
    streakGraceDays = 1,     -- missed days per week that don't reset the streak (0 = off)
    failedCredit = 0.25,     -- a failed run earns this share of P times the share of objectives done
    common = {
        fastShare = 0.75,        -- finished within this share of the time limit...
        fastBonus = 0.20,        -- ...earns this share of P
        noDamage = 10,           -- points when the vehicle stays above noDamageAbove
        firstRun = 15,           -- points for an officer's first finished run since going on duty
        heavyDamage = -25,       -- points (negative): the vehicle ended below heavyDamageBelow
        pedestrianHit = -30,     -- points (negative) for each pedestrian hit with a vehicle
        lightsSiren = -10,       -- missions with quietPatrol = true only (Beat Patrol, Business Check,
                                 -- Illegal Parking Patrol), and only after arrival at the start
        shotSurrendered = -20,
        noDamageAbove = 950,     -- engine and body health above this earns noDamage
        heavyDamageBelow = 500,  -- body health below this costs heavyDamage
    },
}

-- ============================================================================
--                            BONUSES AND PENALTIES
-- ============================================================================
-- See also Part 3 (Player vs police): the rs_ penalties below are for real-suspect cases.

-- The standard list, and the only one the Mission Builder offers. Ids with positive values go in a mission file's
-- bonuses, negative ones in its penalties; either may override the value with points or pctOfPoints. Labels live in
-- locales/en.json (rename them in Admin UI -> Settings -> Names). Built-in missions may also use the extra bonuses
-- written on their mission cards. Decision grades are personal to the officer who decided. Usually changed here:
-- value. Every entry has:
-- kind: 'points' = value is flat points; 'pct' = value is a share of P (0.10 = 10 %)
-- value: the points (kind 'points') or the share of P (kind 'pct'); a negative value is a penalty
-- each: true = counted per occurrence (each arrest, each wrong log); left out = once per run
-- block: the block a mission must contain to use it (left out = any mission)
-- engineOnly: true = awarded by the engine or a block's own setting (e.g. bestPoints); never listed by
-- builder:config, and the loader refuses it in a mission file's bonuses or penalties.
Config.Bonuses = {
    no_participant_downed = { kind = 'pct', value = 0.10 },
    no_weapons_fired = { kind = 'points', value = 10 },
    hostile_arrested = { kind = 'points', value = 5, each = true, block = 'hostile_waves' },
    suspect_alive = { kind = 'points', value = 15, block = 'flee_arrest' },
    no_hostage_hurt = { kind = 'points', value = 15, block = 'protect_rescue' },
    vehicle_stopped_fast = { kind = 'points', value = 15, block = 'pursuit' },  -- stopped within 2 min of the start
    truck_healthy = { kind = 'pct', value = 0.10, block = 'escort' },           -- arrives above 50% health
    -- every clue checked before the first arrest
    clues_first = { kind = 'points', value = 10, block = 'search_area' },
    no_missed_checks = { kind = 'points', value = 15, block = 'skill_check' },
    correct_log = { kind = 'points', value = 5, each = true, block = 'interact_points' },
    wrong_log = { kind = 'points', value = -5, each = true, block = 'interact_points' },  -- penalty
    -- penalty: ramming at over 100 km/h
    hard_ram = { kind = 'points', value = -10, each = true, block = 'pursuit' },
    correct_disposition = { kind = 'points', value = 10, each = true, block = 'field_contact', engineOnly = true },
    procedure_complete = { kind = 'points', value = 10, block = 'field_contact' },        -- once per officer
    all_correct = { kind = 'points', value = 10, block = 'field_contact' },
    subject_alive = { kind = 'points', value = 15, each = true, block = 'field_contact' },
    vehicle_impounded = { kind = 'points', value = 10, each = true, block = 'field_contact' },
    -- decision grades (negative values are penalties)
    wrong_citation = { kind = 'points', value = -5, each = true, block = 'field_contact', engineOnly = true },
    missed_offence = { kind = 'points', value = -5, each = true, block = 'field_contact', engineOnly = true },
    wrongful_arrest = { kind = 'points', value = -25, each = true, block = 'field_contact', engineOnly = true },
    missed_arrest = { kind = 'points', value = -15, each = true, block = 'field_contact', engineOnly = true },
    wrongful_impound = { kind = 'points', value = -15, each = true, block = 'field_contact', engineOnly = true },
    missed_impound = { kind = 'points', value = -10, each = true, block = 'field_contact', engineOnly = true },
    unlawful_search = { kind = 'points', value = -15, each = true, block = 'field_contact', engineOnly = true },
    unsearched_transport = { kind = 'points', value = -10, each = true, engineOnly = true },
    excessive_force = { kind = 'points', value = -10, each = true, engineOnly = true },
    all_taken_alive = { kind = 'points', value = 15, block = 'process_scene', engineOnly = true },
    stop_without_cause = { kind = 'points', value = -15, block = 'pursuit', engineOnly = true },
    lab_fire = { kind = 'points', value = -15, block = 'skill_check' },                 -- penalty: setback
    cook_arrested = { kind = 'points', value = 10, each = true, block = 'flee_arrest' },
    stash_found_fast = { kind = 'points', value = 10, block = 'interact_points' },
    lieutenant_alive = { kind = 'points', value = 25, block = 'hostile_waves' },
    -- claimed server-posted mission calls
    rapid_response = { kind = 'pct', value = 0.10, engineOnly = true },
    -- penalty: shot a real suspect who was never armed
    rs_unarmed_shot = { kind = 'pct', value = -0.25, each = true, engineOnly = true },
    -- penalty: ran a real suspect over on foot
    rs_ran_over = { kind = 'pct', value = -0.25, each = true, engineOnly = true },
    live_scene = { kind = 'pct', value = 0.25, engineOnly = true },                     -- live case: secured the scene
    -- live case: per suspect detained (x his share)
    live_detain = { kind = 'pct', value = 0.50, each = true, engineOnly = true },
    -- live case: per suspect booked (x his share)
    live_book = { kind = 'pct', value = 0.25, each = true, engineOnly = true },
    -- live case: per suspect detained after a surrender, no officer hit (x his share)
    peaceful_arrest = { kind = 'pct', value = 0.15, each = true, engineOnly = true },
}

-- Cosmetic badges only; never the Qbox rank. Each name is a band of numbered levels starting at level;
-- xp stays for old callers.
Config.XPLevels = {
    { label = 'Probationary', xp = 0, badge = 'grey', level = 1 },
    { label = 'Patrol Officer', xp = 1000, badge = 'bronze', level = 10 },
    { label = 'Senior Patrol', xp = 5000, badge = 'silver', level = 25 },
    { label = 'Veteran', xp = 15000, badge = 'gold', level = 38 },
    { label = 'Elite', xp = 40000, badge = 'platinum', level = 50 },
}

-- Level n needs round(first × (growth^(n − 1) − 1) ÷ (growth − 1)) XP. Cosmetic only: never the rank,
-- never pay, never missions. Lv 10 ≈ 1,200 XP, Lv 25 ≈ 5,800, Lv 50 ≈ 37,900.
Config.XPCurve = {
    maxLevel = 50,           -- the last numbered level
    first = 100,             -- XP from level 1 to level 2
    growth = 1.07,           -- each level needs this much more than the one before
    prestigeEvery = 10000,   -- after maxLevel, one prestige star per this much XP
}

Config.Badges = {            -- achievement badge counts
    ironWheels = 20,     -- completed runs with no vehicle damage
    sharpshooter = 10,   -- Gang Shootouts with no participant downed
    roadWarrior = 100,   -- Patrol missions
    partnerInCrime = 50, -- unit runs
    jointTaskForce = 10, -- runs with 2 or more departments
    byTheBook = 100,     -- Best dispositions
    firstResponder = 25, -- mission calls answered with rapid response
}

-- Each officer gets one goal a day and one a week, drawn from the lists below; finishing it earns its points.
-- A goal's stat is one of: arrests, citations, impounds, rescues, vehicles_stopped, evidence, decisions_ok
-- (Best or Acceptable), decisions_best. Stat goals count completed rows only.
Config.Goals = {
    dailyPoints = 50,        -- points for finishing the daily goal
    weeklyPoints = 200,      -- points for finishing the weekly goal
    -- The goals a daily goal is drawn from: id (unique), label (shown to the officer), count (how many) and at most
    -- one of type (a mission type), unit = true (unit runs), missionCall = true (answered calls), crossDepartment =
    -- true (runs with 2+ departments) or stat (above); none of them = any completed mission
    daily = {
        { id = 'patrol_2', label = 'Complete 2 Patrol missions', type = 'patrol', count = 2 },
        { id = 'any_3', label = 'Complete 3 missions of any type', count = 3 },
        { id = 'unit_1', label = 'Complete 1 unit run', unit = true, count = 1 },
        { id = 'calls_2', label = 'Answer 2 mission calls', missionCall = true, count = 2 },
        { id = 'arrests_2', label = 'Make 2 arrests', stat = 'arrests', count = 2 },
    },
    weekly = {                   -- the goals a weekly goal is drawn from (the same fields as daily)
        { id = 'tactical_5', label = 'Complete 5 Tactical missions', type = 'tactical', count = 5 },
        { id = 'cross_2', label = 'Complete 2 cross-department runs', crossDepartment = true, count = 2 },
        { id = 'any_15', label = 'Complete 15 missions', count = 15 },
        { id = 'judgement_15', label = 'Make 15 correct decisions', stat = 'decisions_ok', count = 15 },
        { id = 'impound_3', label = 'Impound 3 vehicles', stat = 'impounds', count = 3 },
    },
}

-- ============================================================================
--                           ITEM REWARDS (OPTIONAL)
-- ============================================================================
-- Off by default. Admin config only: mission files and the Mission Builder never hold rewards.
-- Items must exist in ox_inventory. Never weapons, ammo, armour, bandages or money items.
Config.Rewards = {
    enabled = false,                 -- true = officers can earn items (see the rules above)
    allowTakeBack = false,           -- Admin UI: take a given item back from an online officer (needs ENABLE)
    dailyItemCap = 10,               -- items per officer per day, every source together
    dailyValueCap = 2000,            -- total value of those items per officer per day
    findBonus = 0.10,                -- each lawful evidence find adds this to the run's chance...
    findBonusMax = 0.30,             -- ...up to this much
    -- added to the chance at each scaling tier (0-1; tiers as in Config.Scaling)
    tierChance = { reinforced = 0.05, heavy = 0.10, major = 0.15, critical = 0.20 },
    byType = {                       -- chance per roll, rolls per run, and a weighted pool
        -- tactical = {
        --     chance = 0.25,
        --     rolls = 1,
        --     pool = { { item = 'water', count = { 1, 2 }, weight = 3, value = 20 } },
        -- },
    },
    byMission = {},                  -- same shape as byType, keyed by mission id; replaces the type's entry
    medals = {},                     -- e.g. gold = { item = 'water', count = 1, value = 20 }
    goals = {},                      -- items for finished goals, by daily and weekly
    levels = {},                     -- e.g. [10] = { item = 'radio', count = 1, value = 150 }
    weeklyBoss = nil,                -- a guaranteed item for a completed Weekly Boss
    season = {},                     -- items at a season's end, by champion and top10
    -- matched case-insensitively (WEAPON_PISTOL is refused too)
    forbidden = { 'weapon_*', 'ammo-*', 'armour', 'bandage', 'money', 'black_money', 'cash' },
    useExamplePools = false,         -- true = use examplePools for any type byType leaves empty
    -- Example: safe values (default ox_inventory consumables), by mission type
    -- chance: 0-1, the chance of each roll to give an item
    -- rolls: how many times a finished run rolls
    -- pool: the items one roll picks from: item (ox_inventory name), count (a number or { min, max }), weight (how
    -- likely against the others) and value (dollars, for dailyValueCap)
    examplePools = {
        patrol = { chance = 0.15, rolls = 1, pool = { { item = 'water', count = { 1, 2 }, weight = 3, value = 20 } } },
        investigation = {
            chance = 0.20,
            rolls = 1,
            pool = {
                { item = 'water', count = { 1, 2 }, weight = 2, value = 20 },
                { item = 'burger', count = 1, weight = 1, value = 40 },
            },
        },
        tactical = {
            chance = 0.25,
            rolls = 1,
            pool = {
                { item = 'burger', count = { 1, 2 }, weight = 2, value = 40 },
                { item = 'sprunk', count = { 1, 2 }, weight = 2, value = 25 },
            },
        },
    },
}

-- ============================================================================
--                               FEATURE REWARDS
-- ============================================================================
-- Money and items for the features outside a mission's own pay: the volunteer who plays a suspect, the officer who
-- talks a suspect down, field training and supervisor point awards. Each feature has its own switch (all ship off,
-- so nothing pays until you turn one on in Admin UI -> Settings -> Features) and a money amount ready to use. Every
-- payment is a row of the payments ledger (Admin UI -> Payments: audited, paid once per case, pending until the
-- player logs in, Config.Cash.dailyCap applies). Items are given only while Config.Rewards.enabled is on, under its
-- daily caps, and must exist in ox_inventory (never weapons, ammo or the forbidden names of Config.Rewards).
-- An items list holds { item = 'water', count = 1, chance = 1.0, value = 20 } entries: count a number or { min, max
-- }, chance 0-1 for each payment, value in dollars for Config.Rewards.dailyValueCap.
Config.FeatureRewards = {
    -- The volunteer suspect (the criminal player of Config.Volunteers), paid once per case, and only for a case the
    -- server saw end fairly: officers reached him, he did not drop out or go AFK and his part was not void
    suspect = {
        enabled = false,             -- true = a volunteer suspect is paid for a fair case
        account = 'cash',            -- 'bank' | 'cash' | 'item' (the money is the item named in moneyItem)
        moneyItem = 'black_money',   -- the dirty-money item paid when account = 'item' (must exist in ox_inventory)
        money = {
            got_away = 1500,         -- dollars when he escaped
            caught = 500,            -- dollars when he was detained or booked (he played the part to the end)
        },
        -- Dollars by mission type (a Config.MissionTypes key), e.g. investigation = { got_away = 2000, caught = 600 };
        -- a type or outcome left out pays the money above. Empty = every type pays the money above
        byType = {},
        items = {},                  -- items for a fair case (see the list shape above)
    },
    -- The officer who talked a live-case suspect down (Talk them down), paid once per suspect when the peaceful
    -- arrest counts (the suspect was not AFK), at the end of a case played out (not abandoned, cancelled or flagged)
    surrender = {
        enabled = false,             -- true = the officer who talked a suspect down is paid
        account = 'bank',            -- 'bank' | 'cash' | 'item'
        moneyItem = 'black_money',   -- the money item when account = 'item'
        money = 300,                 -- dollars per peaceful arrest
        items = {},                  -- items per peaceful arrest
    },
    -- Field training (Config.FieldTraining): the trainer for each task he signs off
    ftoSignOff = {
        enabled = false,             -- true = the trainer is paid for each sign-off
        account = 'bank',            -- 'bank' | 'cash' | 'item'
        moneyItem = 'black_money',   -- the money item when account = 'item'
        money = 250,                 -- dollars per task signed off
        items = {},                  -- items per task signed off
    },
    -- Field training: the rookie once every task is signed off and his training is done
    ftoComplete = {
        enabled = false,             -- true = the rookie is paid when his training is done
        account = 'bank',            -- 'bank' | 'cash' | 'item'
        moneyItem = 'black_money',   -- the money item when account = 'item'
        money = 1000,                -- dollars for the finished training
        items = {},                  -- items for the finished training
    },
    -- Supervisor point awards (the Give points Mission control): the officer who got the points
    supAward = {
        enabled = false,             -- true = an officer given points by a supervisor is paid too
        account = 'bank',            -- 'bank' | 'cash' | 'item'
        moneyItem = 'black_money',   -- the money item when account = 'item'
        money = 5,                   -- dollars per point awarded
        maxMoney = 2500,             -- dollars one award pays at most (0 = no limit)
        items = {},                  -- items per award
    },
}

-- ############################################################################
--                               PART 6 · SYSTEM
-- Run limits, anti-exploit checks, the daily reset, admin test mode, retention, backups and webhooks.
-- Usually changed here: Time.resetHour (when the day starts) and how long old data is kept (Retention).
-- ############################################################################

-- ============================================================================
--                                  RUN LIMITS
-- ============================================================================
-- Caps for each run and for the whole server, with the request limits of the tablet.
Config.Limits = {
    maxUnitSize = 4,             -- officers in one unit at most
    maxArmedAlive = 25,          -- armed NPCs alive at any one moment per run
    maxEntities = 80,            -- spawned entities at any one moment per run
    corpseCleanup = 30,          -- seconds before dead NPCs and wrecked vehicles are deleted (bodies a
                                 -- Process the scene objective keeps are deleted when it ends)
    maxCompletionsHour = 8,      -- completed runs per officer per hour
    maxCompletionsDay = 0,       -- completed runs per officer per day (from the daily reset); 0 = no cap
    abandonCooldown = 300,       -- seconds; covers the whole mission type
    startTimeout = 600,          -- default seconds to reach the start (a mission can override it)
    maxConcurrentRuns = 12,      -- runs active server-wide at once; Cross-Department Missions don't count
    maxConcurrentTactical = 4,   -- of those, Tactical runs
    reserveLocations = true,     -- a location in use by one run can't be drawn for another
    -- Milliseconds a player's Qbox data (job, duty, name, callsign) is reused before Qbox is asked again; every Qbox
    -- job, duty or data change clears it at once; 0 = ask Qbox every time (the old behaviour)
    playerInfoCacheMs = 1000,
    -- What happens when a player keeps sending one tablet request past its limit (most allow 6 to 8 a second):
    -- 'block' = the extra requests are refused quietly, as before; 'log' = also one console warning a minute per
    -- player once one request is refused 3 times its limit (at least 20 times) in a minute; 'kick' = that warning,
    -- and the player is dropped from the server. Admins are never warned about or dropped for this
    netRateResponse = 'block',
    -- Bytes a second for the big Admin UI downloads (Audit and Payments → Export, up to 5000 rows): they come in the
    -- background, so the rest of the tablet keeps answering while one loads (below 100000 counts as 100000; 0 = send
    -- each one in one go, as before)
    exportBps = 200000,
}

-- ============================================================================
--                                 ANTI-EXPLOIT
-- ============================================================================

Config.AntiCheat = {
    maxSpeed = 80.0,        -- m/s between objective events before a run is flagged
    presenceRadius = 150.0, -- runs with 2+ participants: fallback presence range for a block with none of its own...
    presenceShare = 0.70,   -- ...for this share of the run to earn points and cash
    -- seconds after the run moves to In progress to remove participants who haven't reached the start
    idleCheck = 180,
    jobRecheck = 10,        -- seconds between active-job and duty re-checks during a run
    outsideKillsToFlag = 1, -- kills of mission NPCs by players who aren't on the run that flag it for review
    voidsToSuspend = 3,     -- this many voided runs...
    voidWindowDays = 30,    -- ...within this many days...
    suspendDays = 7,        -- ...suspends the officer for this many days

    stunNeedsProof = 'flag',  -- 'flag' = a stun counts as before, and one the server did not see (no fall) adds a
                              -- note for staff (nobody's points are held); 'hold' = the same, but that officer's
                              -- points wait for review; 'strict' = a fleeing person only gives up to a stun the
                              -- server saw; 'off' = no check (the old way)
    stunRecheck = 2,          -- seconds 'flag' and 'hold' wait before the note or flag: a report that reaches the
                              -- server before its copy of the suspect shows the fall gets no note when the fall
                              -- shows by then. 0 = decide at once

    -- A player who is not an admin sends a request only admins may send (the money, void and other Admin UI tools;
    -- no officer or supervisor screen sends one, so it is almost always a cheat menu). It is refused as always, and
    -- a console line, kept in Admin UI → System → Problems, names the player and the request: once a minute per
    -- player and request, at most this many lines a minute per player. 0 = refused without a line.
    adminProbeLines = 5,
}

-- ============================================================================
--                                 PERFORMANCE
-- ============================================================================
-- How often Crimson-Police's background loops wake (docs/LOOPS.md lists every one). Markers near you still draw
-- every frame and run deadlines keep their own timers; only the idle and far-away waits stretch. Also how often the
-- tablet's updates go out and which answers come in the background (both off as shipped).
Config.Performance = {
    -- Multiplies the idle/far wait of every Crimson-Police loop; 1 = the values in docs/LOOPS.md, 2 = half as
    -- often; 1-4
    loopScale = 1.0,
    -- Milliseconds between two tablet updates of the same kind to one player (a run's progress, the board, the
    -- unit): quicker ones are merged into one, sent when the wait is over; 0 = each sent at once, as before;
    -- 250-500 cuts the traffic of busy runs; 0-2000
    pushGapMs = 0,
    -- Tablet answers bigger than this many bytes (boards, mission lists, admin lists) come in the background at
    -- Config.Limits.exportBps, so the rest of the tablet keeps answering; 0 = only the Admin UI exports, as
    -- before; 0-10000000
    latentAboveBytes = 0,
    -- Metres: the objective markers that draw every frame (escort, suspect, scene, rescue, clue, point and device
    -- markers) draw only within this distance, so a far marker costs nothing; 0 = each marker's own distance (30-150
    -- m), as before; the checkpoint course keeps its own (it times your pass through each checkpoint); 0-150
    markerRange = 0,
}

-- ============================================================================
--                                     TIME
-- ============================================================================
-- Hour (0–23, server time) of the daily reset: Type of the Day, daily goals,
-- streak days, the daily cash cap and the retention job. Weekly things reset
-- at this hour on Config.Leaderboard.weekStartsOn.
Config.Time = { resetHour = 0 }

-- ============================================================================
--                               ADMIN TEST MODE
-- ============================================================================

Config.Testing = {
    enabled = true,        -- true = admins may run test runs of missions (Admin test mode)
    maxTesters = 8,        -- players in one test run, including the admin
    useStartRoute = false, -- default for the start-route toggle
    allowTeleport = true,  -- teleport controls in test runs
    debugOverlay = true,   -- the debug overlay control
    -- Default key of the admin test panel and the test invitation (each admin or tester can rebind it in GTA Settings ->
    -- Key Bindings -> FiveM; this default only reaches players who never bound it; '' = no default key). Not F9:
    -- sc-multijob uses F9
    panelKey = 'F7',
    -- Milliseconds (0-1000) the test controls key is ignored after the panel or the invitation prompt gives your mouse
    -- and keyboard back, so the press that let go does not take the panel straight back (0 = off)
    panelKeyGuardMs = 300,
    -- Check spawn points (Admin UI -> Testing): your own game visits every point of a mission's locations and tells
    -- you which ones are under the ground, floating, in water, in a wall or inside a building that never loads. It
    -- spawns nothing and moves only you (unseen and unhurt, back where you were afterwards)
    spawnCheck = {
        enabled = true,         -- false = no spawn point check
        -- Milliseconds (1000-30000) your game waits for the map around a location to load before checking its points
        sceneTimeoutMs = 8000,
        -- Metres (0-400): points further than this from where you are are checked from right over them (you are moved
        -- there); closer ones from where you stand (0 = move to every point)
        moveWithin = 150.0,
        -- true = also check every point of the routes (where cars drive and suspects run), which takes much longer;
        -- false = only where people, vehicles and objects appear and the objective markers
        routes = false,
        teleport = true,        -- the "Teleport here" button next to a checked point (puts you on the ground there)
    },
}

-- ============================================================================
--                                  RETENTION
-- ============================================================================

Config.Retention = {
    runArchiveMonths = 12,  -- move older runs to cp_mission_runs_archive; 0 = never
    auditDays = 180,        -- delete older audit rows; 0 = keep forever
    missionCallDays = 90,   -- delete older mission call history; 0 = keep forever
}

-- ============================================================================
--                                   BACKUPS
-- ============================================================================
-- Admin UI → System → Backups: copies of every Crimson-Police table and the mission files, in saves/_backups.
Config.Backups = {
    keep = 7,               -- backups kept; the newest and the latest automatic one are never removed
    daily = false,          -- true = one backup at every daily reset
    -- true = after a restore that stopped part way, payments and new runs stay held (also after a restart) until a
    -- restore works; false = a restart ends that lock and the server goes on with the store as it is
    holdAfterFailedRestore = true,
}

-- Discord webhooks are read from convars in server.cfg, never stored here.
-- A convar that is missing or empty turns that webhook off.
--   set cp_webhook_board      "https://discord.com/api/webhooks/..."   (weekly top 3, season results)
--   set cp_webhook_audit      "https://discord.com/api/webhooks/..."   (payout changes and admin actions)
--   set cp_webhook_flags      "https://discord.com/api/webhooks/..."   (flagged runs, voids, disputes)
--   set cp_webhook_builder    "https://discord.com/api/webhooks/..."   (publish, archive, rollback, lock breaks, code edits)
--   set cp_webhook_operations "https://discord.com/api/webhooks/..."   (Cross-Department launches and results)

config/blocks.lua holds the range and default of every Mission Builder setting, so a server owner can widen or narrow what builders may pick without touching code. It follows the Mission Builder tables exactly:

-- Mission Builder ranges and defaults.

-- What a builder may set for each block (one step of a mission) in the Mission Builder. A { min, max, default }
-- triple is the range a builder may pick in and the value a new objective starts with; { min, max } has no default.
-- Usually changed here: the ranges, to give builders more or less room. A pick from a list has:
-- options: the choices a builder may pick from
-- default: the value a new objective starts with (true or false for an on/off switch)
Config.Blocks = {
    details = {                   -- the Details step, for every mission
        difficulty = { 1, 3, 2 },               -- stars
        officers = { 1, 4 },                    -- min and max officers the builder may set
        timeLimit = { 120, 1200, 600 },         -- seconds a run has after it moves to In progress
        startTimeout = { 300, 900, 600 },       -- seconds the officers have to reach the start
        cooldown = { 300, 3600, 1200 },         -- seconds before an officer may take the mission again
        vehiclePenalties = { default = true },  -- false turns off the heavy vehicle-damage penalty
    },

    escort = {
        vehicle = 'stockade', -- default pick from Config.Builder.allowed.escortVehicles
        speed = { 20, 120, 60 }, -- km/h the escorted vehicle drives at most
        style = { options = { 'careful', 'normal', 'fast' }, default = 'normal' }, -- always lane-following
        toughness = { 0.5, 3.0, 1.5 }, -- × vehicle health
        stoppedFail = { 15, 120, 60 }, -- seconds the escorted vehicle may stand still before the case fails
        arrival = { 10, 50, 20 }, -- metres from the destination that count as arrived
        stops = { 0, 5, 0 }, -- stop points added with E while recording
        stopWait = { 10, 60, 20 }, -- seconds at each stop; never counts toward stoppedFail
        ambushPoints = { 1, 10, 5 }, -- ambush points along the route
        ambushGap = 150.0, -- minimum metres between ambush points
        ambushWaves = { 1, 5, 2 }, -- ambushes on one escort
        carsPerWave = { 1, 5, 2 }, -- attacker cars in each ambush
        perCar = { 1, 4, 2 }, -- attackers per car; weapons, accuracy and armour as hostile_waves
        presenceRange = { 50, 800, 300 }, -- from the escorted vehicle
    },

    checkpoint_route = {
        checkpoints = { 2, 20 },                                   -- checkpoints a builder may place
        use = { options = { 'all', 'random' }, default = 'all' },  -- every checkpoint, or a random few
        radius = { 3, 20, 10 },                                    -- metres: how close counts as at the checkpoint
        stopFor = { 0, 30, 10 },                                   -- seconds to stay at each checkpoint (0 = drive through)
        vehicleRequired = { default = true },                      -- a checkpoint only counts while driving a vehicle (any vehicle)
        medals = { default = false },                              -- when on: Gold, Silver and Bronze times in seconds
        contactPenalty = { 0, 10, 2 },                             -- seconds added per hit
        presenceRange = { 50, 800, 300 },                          -- from the next checkpoint or the nearest partner, whichever is closer
    },

    protect_rescue = {
        npcs = { 1, 6, 3 },                                   -- people to protect or rescue
        peds = { 'a_m_m_business_01', 'a_f_y_business_01' },  -- their ped models
        restrained = { default = true },                      -- they start tied up and must be freed
        freeTime = { 1, 15, 6 },                              -- seconds to cut one person's restraints
        hitPenalty = { 0, 100, 50 },                          -- points lost when an officer hits one of them (0 = none)
        failIfDies = { default = true },                      -- the case fails when one of them dies
        presenceRange = { 50, 800, 150 },                     -- from the nearest NPC being protected
    },

    search_area = {
        startRadius = { 200, 1000, 600 },  -- metres: the search circle at the start
        clues = { 1, 5, 3 },               -- clues to find
        shrinkTo = { 300, 150, 50 },       -- circle radius after each clue
        fugitives = { 1, 5, 1 },           -- people hiding in the area
        runDistance = { 10, 60, 30 },      -- metres: a fugitive runs when an officer gets this close
        presenceRange = { 50, 800, 100 },  -- margin outside the current search circle (inside always counts)
    },
}

-- The blocks below are assigned after the table: field_contact and process_scene are new, the others
-- carry the settings the police actions, raids and tactical variants added.

Config.Blocks.field_contact = {
    -- parked = check parked cars; scene = people at a scene; stop = the car a pursuit stopped
    mode = { options = { 'parked', 'scene', 'stop' }, default = 'scene' },
    people = { 1, 4, 1 },               -- scene mode; stop mode takes them from the stop; parked has none
    cars = { 0, 6, 1 },                 -- parked: cars to check; scene: 0 or 1
    -- truths from Config.Custody.profileSets
    profileSet = { options = { 'scene', 'traffic', 'parking', 'stolenCar' }, default = 'scene' },
    approach = { 10, 40, 25 },          -- metres: people react when the first participant is this close
    probableCause = { default = true }, -- a vehicle search needs probable cause or consent
    -- cuff = an arrest ends with the cuffs; handover = it ends at the prisoner van
    custody = { options = { 'cuff', 'handover' }, default = 'handover' },
    returning = { 0, 100, 25 },         -- parked: chance a driver comes back (at most once per run)
    escapeFails = { default = true },   -- off: an escape costs missed_arrest instead of failing
    bestPoints = { 0, 20, 10 },         -- correct_disposition points per Best decision
    minSpots = 5,                       -- parked: kerb spots per location (scene: 3 person spots)
    presenceRange = { 50, 800, 150 },   -- from the nearest contact not yet decided
}

Config.Blocks.process_scene = {
    bodies = { 0, 8, 4 },               -- bodies kept (the latest ones)
    tagTime = { 2, 15, 5 },             -- seconds: Photograph & tag
    bagTime = { 2, 15, 6 },             -- seconds: Bag body
    releaseTime = { 2, 15, 8 },         -- seconds: Release to coroner
    coroner = { default = true },       -- a coroner van collects the bags; off = release at the scene marker
    presenceRange = { 50, 800, 150 },   -- from the nearest body or the scene marker
}

Config.Blocks.pursuit = {
    mode = { options = { 'follow', 'stop' }, default = 'stop' },             -- stop the car, or follow it unseen
    vehicles = { 1, 5, 1 },                                                  -- suspect vehicles
    route = { options = { 'free', 'recorded' }, default = 'free' },          -- flee freely, or along a recorded route
    speed = { 40, 160, 120 },                                                -- km/h the suspect drives at most
    style = { options = { 'cautious', 'reckless' }, default = 'reckless' },  -- how the suspect drives
    suspects = { 1, 4, 1 },                                                  -- per vehicle
    footFlee = { 0, 100, 20 },                                               -- chance to flee on foot after the stop
    holdDistance = { 50, 300, 150 },                                         -- Follow mode
    lostDistance = { 150, 600, 250 },                                        -- Follow mode: metres away that count as losing the car...
    lostSeconds = { 5, 30, 10 },                                             -- ...for this many seconds
    duration = { 60, 600, 180 },                                             -- Follow mode: seconds to keep following
    presenceRange = { 50, 800, 400 },                                        -- from the nearest suspect vehicle, or suspect on foot
    -- rolled when the lights trigger fires; must add up to 100
    responses = { yield = 0, flee = 100, fight = 0 },
    -- contact: the next field_contact objective works the stopped car and its people
    handoff = { options = { 'arrest', 'contact' }, default = 'arrest' },
    -- off = no observation; pace = pace the car to prove speeding; follow = follow it to prove a violation
    observe = { options = { 'off', 'pace', 'follow' }, default = 'off' },
    zoneSpeed = { 50, 130, 80 },        -- km/h: posted speed for observe = pace
    overMin = { 10, 60, 20 },           -- km/h over the posted speed: rolled between overMin...
    overMax = { 10, 60, 45 },           -- ...and overMax
    driveBy = { 0, 100, 0 },            -- chance armed passengers shoot from the car (participants only)
    ram = { 0, 100, 0 },                -- chance a boxed-in driver rams once
    -- metres along the route from the nearest participant or the observation point: negative = upstream,
    -- so the car drives past the officer; 0 = off. Kept within 250 m so a player is always in range
    spawnOffset = { -250, 250, 0 },
    paceTolerance = { 0, 10, 5 },       -- km/h: the median of the pace samples may be this far under the limit
    -- Street Race Bust and other race loops: seconds a racer's car or driver may stay with the game of a player who
    -- is not on the run before the console names that player (the host's game always takes it back); 0 = never
    outsiderWarn = 10,
}

Config.Blocks.interact_points = {
    points = { 1, 10 },                                        -- points to work
    use = { options = { 'all', 'random' }, default = 'all' },  -- every point, or a random few
    progress = { 1, 30, 5 },                                   -- seconds the progress bar takes at each point
    label = 'Checking…',                                       -- the progress bar's text
    animation = 'clipboard',                                   -- default pick from Config.Builder.allowed.animations
    logResult = { default = false },                           -- officers log what they found at each point (graded)
    logChoices = { 2, 4, 2 },                                  -- choices offered when logging a result
    presenceRange = { 50, 800, 150 },                          -- from the nearest point not yet done
    together = { 1, 4, 1 },                                    -- different officers who must finish points within the window (1 = off)
    togetherWindow = { 3, 15, 6 },                             -- seconds
    soloProgress = { 3, 20, 8 },                               -- seconds per point when together can't be met (one participant left)
    -- what hidden finds are: device = a device to work next; seize = evidence to seize
    hiddenKind = { options = { 'device', 'seize' }, default = 'device' },
    finds = { 0, 100, 0 },              -- chance a plain point yields evidence
}

Config.Blocks.skill_check = {
    checks = { 1, 8, 4 },               -- skill checks in a row
    -- how hard each check is (the default lists one per check)
    difficulty = { options = { 'easy', 'medium', 'hard' }, default = { 'easy', 'medium', 'medium', 'hard' } },
    missPenalty = { 0, 120, 30 },       -- seconds off the timer
    failAfter = { 1, 3, 2 },            -- misses in a row
    presenceRange = { 50, 800, 150 },   -- from the device or point being worked on
    -- what failAfter misses do: 'fail' the case (as today) or a 'setback' (a recovery step, then a retry)
    onFail = { options = { 'fail', 'setback' }, default = 'fail' },
    setbackTime = { 5, 30, 10 },        -- seconds: the recovery step (e.g. Ventilate)
    retryAfter = { 10, 120, 30 },       -- seconds before the checks can be tried again
}

Config.Blocks.flee_arrest = {
    suspects = { 1, 10, 1 },                                -- suspects to arrest
    responses = { surrender = 50, flee = 30, fight = 20 },  -- must add up to 100
    armedChance = { 0, 100, 20 },                           -- percent chance a suspect is armed
    weapons = { 'WEAPON_PISTOL' },                          -- weapons an armed suspect may carry
    escapeDistance = { 200, 800, 400 },                     -- metres from every officer that count as escaped...
    escapeSeconds = { 10, 60, 20 },                         -- ...for this many seconds
    -- what makes a suspect give up: aim (aimed at), stun (tased) or close (an officer stays close)
    givesUp = { options = { 'aim', 'stun', 'close' }, default = { 'aim', 'stun', 'close' } },
    aimDistance = { 5, 15, 10 },                            -- gives up when aimed at within this distance,
    closeDistance = 3.0,                                    -- ...or when a participant stays this close...
    closeSeconds = 3,                                       -- ...for this long (or when stunned)
    presenceRange = { 50, 800, 250 },                       -- from the nearest suspect not yet cuffed
    demeanour = {
        options = { 'rolled', 'compliant', 'nervous', 'evasive', 'runner', 'hostile' },
        default = 'rolled',                                 -- rolled: Config.Custody.demeanour
    },
    feint = { 0, 50, 0 },                                              -- chance a surrendered unarmed suspect bolts
    custody = { options = { 'cuff', 'handover' }, default = 'cuff' },  -- end at the cuffs or at the prisoner van
}

Config.Blocks.hostile_waves = {
    waves = { 1, 6, 3 },                                   -- waves of hostiles
    -- every armed NPC in the mission together: at most Config.Builder.maxHostiles
    perWave = { 1, 15, 7 },
    nextWaveAlive = { 0, 5, 2 },                           -- next wave when this many or fewer are alive...
    nextWaveAfter = { 30, 300, 90 },                       -- ...or after this long
    weapons = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL' },  -- default pick from Config.Builder.allowed.weapons
    accuracy = { 5, 60, 25 },                              -- what NPCs get is capped by Config.NpcCombat.accuracyMax
    armour = { 0, 100, 0 },                                -- armour of each hostile
    health = { 100, 400, 200 },                            -- also the range for the boss
    -- hold = they stay in cover; balanced = some push; push = they advance on the officers
    behaviour = { options = { 'hold', 'balanced', 'push' }, default = 'balanced' },
    surrender = { 0, 100, 30 },                                                              -- chance to surrender under 25% health
    peds = { 'g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01', 'g_m_y_lost_01' },  -- hostile ped models
    -- when on: model, health, armour and weapon from the ranges above
    boss = { default = false },
    blockTraffic = { 0, 200, 120 },                        -- metres around the start kept free of traffic (0 = off)
    spawnPointsPerHostile = 1.5,                           -- spawn points needed per hostile in the largest wave
    presenceRange = { 50, 800, 150 },                      -- from the nearest living hostile
    behaviourRoll = { default = false },                   -- on: behaviour weights rolled per run instead of one behaviour
    spawnSets = { 0, 4, 0 },                               -- named spawn sets per location (0 = off)
    spawnSetsUsed = { 1, 3, 2 },                           -- sets used per run, shown as the intel line
}

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
  - missionBan (action, 1–24 h): from Department Report bars one online officer of his department with a lower grade (never his own license) from missions, with a reason; missionBanPerDay (3). He cannot accept (nor his unit), claim or join a Cross-Department Mission (err.mission_banned / err.member_mission_banned); his board shows "Mission ban until 18:40 (by Sgt Doe)". The tablet stays usable (not a suspension, which stays admin-only) and a running mission goes on. The setter lifts it from the same dialog, an admin from Officers → Today & cooldowns (antiFarmOverride); all audited under flags. Kept in cp_officers.mission_ban.
  - callLane: the department's own lane of mission calls (gap range, open at once up to callLaneMaxOpen, areas, callable types with weights 0–10), one call at a time, only to idle units all of that department; other departments never see its calls and cannot claim them (err.mc_other_department), nor can the setter's unit (err.mc_own_call). Lane calls count against Config.MissionCalls.maxOpen; the server's flow counts only its own calls against its target. Saved in cp_mission_calls.department; Dispatch tags it "SAST call". staffCallWait replaces Config.MissionCalls.staffCooldown for its supervisors' staff calls (the one who shortened it keeps the config wait).
  - notices: a short notice (noticeMaxLength, 1–30 days) on his department's Home Announcements only; banned words apply; noticesPerDay (5); at most 5 running per department (besides the admins' 5); any supervisor of the department may end one; audited. crossDept { join, places }: keeps its officers out of Cross-Department Missions (err.op_department_out) or caps their places (err.op_department_full, 0 = no cap); never relaxes, so it applies to the setter too.
  - boards { showToOthers, metrics }: other departments see its officers by callsign only (rows, profiles, Home's top 3, picture hidden), and its own officers see only the ticked Rank by tabs (Points always); presentation only. reviewRules { secondVoid, adminOnlyKinds }, stricter only: a supervisor's Void stays pending until a second supervisor of the department voids too (a restart clears it); listed flag kinds go to admins only; admins void at once.
  - twists { offered, ticked }: narrows the accept step of units it leads to the offered twists (among Config.Events.twists) and pre-ticks the ticked ones; another is refused (err.twist_department).
  - typeOfTheDay (choice): picks one type for the next day (never today), once a day (err.tod_picked_today; admins may correct it); that day its officers earn Config.Events.todMultiplier on it instead of the server's type, except the setter and his unit; read back from yesterday's last audit row, so a restart keeps it; switching off drops it at once.
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

Cases with real suspects (live crimes and volunteer suspects, both off by default; the README section "Rules for cases with real suspects" gives the same rules to paste into a server's rules):

- Least force. Tase, tackle and cuff; shooting a suspect who never had a gun or running one over on foot is a penalty (rs_unarmed_shot, rs_ran_over) and a flag. A suspect cuffed while down counts only Config.RealSuspects.neutralisedShare of a detain, one cuffed while AFK nothing: no points come from hurting a player.

- No live tracking. Officers work from the reported place and the "last reported" points; asking anyone outside the case where a suspect is, is a violation.

- No case against yourself or a friend. Never take a case against your own characters or someone you play with; the server refuses most of these and flags the rest for review.

- Suspects play it out. Crew members and volunteers may run, hide, talk and give up; logging off, switching character or entering an instance to escape counts as leaving and is shown to staff. Volunteers say yes only when they can play now, reach the waypoint in time and stay in the area they are given; a no costs nothing, a no-show or walking away is a strike, and Stop or Cancel this case on the volunteer command is always available.

- Staff decide from the case timeline. Reports about a case are decided from its timeline, damage ledger and flags on the Admin UI Real suspects screen; nobody reads or reviews a case they were a suspect in.

Discipline ladder: verbal warning → run voided (points removed, held cash not paid) → 7-day Crimson-Police suspension → removal from the system and a standard write-up.

## Performance, testing & acceptance

The release is accepted when every check below passes on a test server with at least 10 officers of both departments (the in-game run is docs/IN_GAME_CHECKLIST.md; the automated suite is docs/TESTING.md).

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
- ☐ Profile: XP follows Config.XPCurve with one toast per level and "XP pending review" on flags; avatar, bio, report and commendation rules; personal accents only from the department.
- ☐ Desks open the tablet only within the box plus 2 m for their departments; with requireItem every other way needs the item.
- ☐ Every player-facing text is in locales/en.json; tools/check_contracts.py reports no missing key.
- ☐ With Config.Database.enabled = false every check passes the same way, kept in the saves folder across restarts and moved by /CrimsonPoliceAdmin storage copy.

## Build order

Each step is proven by its acceptance checks (Performance, testing & acceptance) before the next starts; docs/ARCHITECTURE.md §5 has the module of each.

| Phase | Steps (in order) |
|---|---|
| 1 · Core | Resource skeleton and migrations; integrations; access, roles and permissions; Officer UI and theming; draw and run lifecycle; route to the start; real calls and alert suppression; downed participants; the first blocks and missions with test mode; objective validation; points; cash; the weekly board |
| 2 · Teams and full catalog | Units; scaling; the remaining blocks and missions; Supervisor UI, Admin UI, payouts and disputes; Cross-Department Missions |
| 3 · Seasons and events | Monthly, season and department boards, badges and goals; the department challenge; special events |
| 4 · Mission Builder | Builder UI, block settings and placement; route recording and test drive; test, publish, versions, locks and Lua export |
| 5 · Newer features | Foundation (migrations 003–006, hooks, stats, decisions, held bodies); police actions; new missions and block upgrades; Dispatch; team tools; progression and profile; item rewards; access and tablet shell; documentation and release (tools/check_all.sh passes) |

Go live after Phase 2 (units, the full catalog and the Supervisor and Admin UIs needed to review flagged runs). The route, real-call, alert and downed steps enforce Hard rules 15–18 and are never skipped or postponed. Phases 3 and 4 ship once the live server has run 2 weeks with fewer than 2 disputes a week, their checks pass and command staff sign off.

## Server owner checklist

Settings and choices only the server owner can make.

- ☐ Set each department's supervisorGrade to your real Qbox grade level. SC-Dispatch's roster treats grade 4 and up as command staff. The start-up check (/CrimsonPoliceAdmin check) lists each department's Qbox job and grades, and warns when a job does not exist in Qbox or when nobody or everybody would be a supervisor.

- ☐ Replace the placeholder payouts in Config.MissionTypes and Config.Events.weeklyBoss with amounts that fit your economy.

- ☐ Give admins the ace in server.cfg, e.g. add_ace group.admin crimsonpolice.admin allow (not needed for Qbox admins while Config.QboxAdmins is true). The start-up check says whether group.admin can open the Admin UI, and when a player is refused /CrimsonPoliceAdmin the server console gets one line with the add_ace line that makes them an admin.

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


- ☐ Test every new location at Heavy tier in Admin UI → Testing before go-live.

- ☐ Check the mission desk coordinates against your station MLOs, or turn desks off (Config.Tablet.access.desk).

- ☐ To use the tablet item or requireItem, paste items/ox_inventory_items.lua into ox_inventory and copy the image into ox_inventory's image folder.

- ☐ Item rewards ship off (Config.Rewards.enabled = false): leave them off, or set enabled = true and either switch on the example pools (useExamplePools = true) or fill Config.Rewards with items that exist in your ox_inventory and suit your economy.

- ☐ Avatar links: leave them off, or set the allowed hosts you trust.

- ☐ Tell officers that sc-police's /imp and /depot must never be used on mission vehicles: use the tablet's Impound. A participant's /imp fails the objective and flags the run.

- ☐ Optional clean-up: tests/zone_lint_baseline.txt lists the built-in locations of different missions that sit closer than 200 m today. They never run at the same time (runtime zone clearance), so nothing is required; moving one later needs a retest in Admin UI → Testing.

- ☐ Review config/banned_words.txt and Config.Profile.avatarUrls.hosts for your community (Imgur is blocked in the UK and some other regions).

- ☐ Known SC-Dispatch behaviour, not fixable from Crimson-Police: when a dispatcher detaches an officer from a real call, sc-dispatch's client un-marks them as responding (sc-dispatch client/main.lua:2277-2282). Within 60 seconds of marking, Crimson-Police's anti-dodge rule then treats that as a normal abandon (type cooldown), because no server-side detach signal exists. Tell dispatchers to avoid Detach in the first minute; the type cooldown (Config.Limits.abandonCooldown, 5 minutes) runs out on its own.

- ☐ Database off: the new tables live in the saves folder like the others; back up the saves folder before updating, and use /CrimsonPoliceAdmin storage copy to move them with the rest.

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

