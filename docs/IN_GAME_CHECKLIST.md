# In-game checklist

Covers every in-game check in 74800bb..HEAD (M3-M11, R6, R7, V1-V27, RP1, K7-K23, Q8-Q23, L2-L7, A1-A12, B1-B17, O1-O15, P1-P22, C14, X11). The step id in brackets says which commit a check belongs to.

## Before you start

1. Use a test server, not the live one, with Crimson-Police, ox_inventory, sc-dispatch and Crimson-Contracts running.
2. Turn Config.Debug on (Admin UI -> Settings, or config.lua) and keep the server console and resmon open.
3. Have one admin account (Qbox admin) that can open /CrimsonPoliceAdmin and the F7 test panel.
4. Have two officers on duty in two departments (for example SAST and FIB), able to form a unit together.
5. Have a supervisor grade: a SAST sergeant (grade 4 or the grade your config names), and a second SAST sergeant for the two-supervisor checks.
6. For the Supervisor checks, switch on the master switch first (Admin UI -> Permissions -> Mission controls; Config.Permissions.supervisor.missionControls ships false) and then each control the check names.

## Officer tablet

- [ ] Tablet -> My options: change the look and tablet size, they apply at once; My keys says "not set" for unbound keys and names a bound one; Edit profile -> Look -> More options opens the screen. (O3)
- [ ] Admin -> Settings -> Officer options -> enabled off: My options is gone from the tablet. (O3)
- [ ] My options -> Mission HUD: HUD side Left, size 1.2, Compact on, start Beat Patrol: the HUD is at the left, bigger, one objective line, the "2/4" count and the timer; notifications stay top right. Fewer animations: the HUD appears without sliding in. (O4)
- [ ] Admin -> Settings -> Officer options -> allow hudSide off: the HUD goes back to the right for everyone. (O4)
- [ ] My options -> Easier to read: colour-blind look plus "Use my tablet look on the HUD": the HUD, result card and notifications use those colours and your accent. Text size Large makes the tablet and HUD text bigger. Relog: both still apply before you open the tablet. (O5)
- [ ] Admin -> Settings -> Officer options -> allow hudLook off: the HUD goes back to the department theme. (O5)
- [ ] My options -> Pop-ups: Fewer pop-ups during a mission, then a colleague sends a unit invite during Beat Patrol: no pop-up, the bell shows it; an off-route warning still pops up. (O6)
- [ ] Result card time 10: the result card closes after 10 s. Notification time Long: a toast stays 8 s. (O6)
- [ ] My options -> Sounds: Mission call tone off (next call pops up silently), Objective cues off (checkpoints pass without the cue), Unit tone off (invite toast without the tone). (O7)
- [ ] My options -> Mission Board: favourite Tactical shows first with a Favourite badge; hide Training, it folds under "Hidden types (1) - Show" and can still be accepted; hiding all four is refused. (O8)
- [ ] Accept in one click: Accept on Patrol starts the run and sets the route at once; the warnings show under the cards. (O8)
- [ ] My options -> Dispatch: Call pop-ups = Favourite types only: a Patrol call shows on Dispatch with no pop-up, a Tactical call pops up. (O9)
- [ ] Tablet key opens Dispatch after a call: press the tablet key within 20 s of a call, the tablet opens on Dispatch. Claim in one click starts the claim at once. (O9)
- [ ] Open on = Active Mission: during a run the tablet opens on Active Mission. Remember my filters: Near me on Dispatch and Monthly on the Leaderboard stay after close and reopen. (O9)
- [ ] My options -> During a mission: Distances = Feet and miles: the HUD route line and Dispatch read in mi / ft. (O10)
- [ ] Abandon asks in a dialog off: one press of Abandon shows "Click again to abandon", after 3 s it resets, two presses abandon and the type cooldown starts. (O10)
- [ ] Recalculate in one click: Recalculate route draws the new route at once and the recalculations left drop by one. (O10)
- [ ] Bind the ready key and the Dispatch key in GTA Settings -> Key Bindings -> FiveM: the ready banner says "Or press <key>.", a mission call pop-up ends "<key> opens Dispatch."; Key hints off in My options -> Pop-ups puts both back as before. (O11)
- [ ] My options -> Map -> Objective GPS: Waypoint, Business Check: the waypoint jumps to each door in turn; no yellow Crimson-Police line besides it. With the Radio Silence twist: no waypoint and no line. (O14)
- [ ] Colour-blind map colours on: a Gang Shootout circle and hostiles are purple, no red or green objective blips; HUD objective line off removes the "Destination · distance" line. (O14)
- [ ] My options -> Mission Board -> My usual twists: tick Time Crunch; Accept Patrol opens with Time Crunch ticked and the bonus line shows it; untick and accept: no twist. A mission call claim also has it ticked. (O15)
- [ ] Accept Tactical with Armored Hostiles and Radio Silence ticked: the dialog says "+50% points, x1.56 cash"; the HUD chip and Active Mission show both twists; the map shows only the objective's area with no GPS line. (M8b)
- [ ] On a Bomb Disposal draw a notice says Armored Hostiles was dropped; in a unit of 2 the member's ready check names the twists. (M8b)
- [ ] Claim a mission call with Time Crunch: the timer starts 25% shorter. Complete a run: one "Twist: <name>" line per twist and the cash is base x tier x the stacked multiplier. (M8b)
- [ ] Accept a mission, then set your own waypoint elsewhere: the yellow Mission start pin and its line stay until you arrive; Set GPS on the tablet makes the line the waypoint again (one line). (M9)
- [ ] Armored Truck Escort: the HUD shows "Escorted vehicle" or "Destination" with a distance; Objective GPS on the tablet sets a waypoint and the yellow objective line goes off while it is set. (M10)
- [ ] Unit screen -> Cross-Department Mission card -> Leave (or Leave the waitlist): a confirm opens; Cancel keeps you in, Confirm leaves. (K21)
- [ ] At 1080p, 1440p and another UI scale, open the citation offence picker, the Leaderboard filters, Profile and an Admin Settings dropdown: the list opens inside the tablet, arrows / Home / End / Enter / typing work, Escape closes the list first, a click outside closes it, the value saves. (K23)
- [ ] Leave the route during a run with the tablet closed: the off-route warning pulses three times and then stays highlighted; live dots in the tablet do the same. (K18)
- [ ] Fill an officer's inventory to the weight limit and accept a custom mission that gives an item: "no room" toast, no item, the run starts; no orphan is logged at the end. (K7)
- [ ] With Config.Tablet.access.requireItem = true, an officer without the tablet item away from a station desk cannot accept a mission or claim a call; at the desk he opened the tablet at he still can. (K8)
- [ ] Open and close the tablet during a run: sidebar badges and Dispatch look the same on reopen; the run bar updates at once on each objective change. (Q16, Q17)

## Supervisor

- [ ] As a SAST sergeant (master switch off, as shipped): Supervisor -> Mission controls is in the sidebar; Mission cooldowns -> Tactical x0.5, Save with a reason: the row shows "Changed by" and the change wait counts down. (P5)
- [ ] Cooldowns are server-wide: a SAST and an FIB officer's Gang Shootout lock are both 10 min instead of 20; the sergeant himself keeps 20. An FIB sergeant sees the same values and can put them Back to config with a reason. (P5)
- [ ] With every Config.MissionControls.controls.*.on = false and the master switch off, the screen is gone after reopening the tablet. (P5)
- [ ] Start a 15-minute happy hour: a SAST officer takes Beat Patrol twice in a row; Home and the Mission Board banner count down and name the sergeant; the sergeant still has his cooldown and the banner says so; a second happy hour the same day is refused. (P6)
- [ ] Admin UI -> Live shows the happy-hour chip; End now brings the cooldowns back at once. (P6)
- [ ] Department Report -> a SAST officer with a Gang Shootout cooldown -> Clear cooldown with a reason: he gets a toast and his card unlocks. (P7)
- [ ] With "+ minutes" switched on, press "+ minutes", 2 on a live SAST run: the participants are told and the HUD timer gains two minutes. (P7)
- [ ] Time to reach the start: set SAST to 900 s: a SAST-led unit's HUD shows 15:00 after accept, an FIB-led unit still 10:00. (P8)
- [ ] NPC difficulty 'easy' for SAST: Gang Shootout hostiles go down faster for a SAST-led unit, result points the same as 'normal'. Largest unit 3: a SAST leader's fourth invite is refused. (P9)
- [ ] Mission types on the board: switch Tactical off for SAST: SAST sees it locked "Off for SAST by command", FIB can accept it. Recommend Patrol: it shows right after a SAST officer's favourites with "Recommended by command". (P10)
- [ ] Mission ban: ban a SAST trooper for 1 h from Department Report: toast, "Mission ban until <time> (by <you>)" with every card locked, call claim and Cross-Department join refused. Admin -> Officers -> him -> Today & cooldowns -> Lift ban opens his board at once. (P11)
- [ ] Department call lane every 120-240 s, Patrol only: SAST officers get "SAST call" Patrol calls every 2-4 minutes, FIB never sees them, the sergeant's own unit cannot claim them. (P12)
- [ ] Department notices: a notice posted in Supervisor UI -> Mission controls shows on SAST Home under Announcements, not for FIB. (P13)
- [ ] Cross-Department participation, opt SAST out, launch a Cross-Department Mission: SAST boards show the operation but Join says the department opted out. (P13)
- [ ] Leaderboard visibility = callsigns only: an FIB officer's Leaderboard shows SAST officers by callsign. (P14)
- [ ] Review rules -> "A Void needs a second supervisor": one SAST sergeant's Void shows "Void pending" and the row stays; a second SAST sergeant's Void voids it. (P14)
- [ ] Twists offered: offer only Time Crunch, pre-ticked: a SAST leader's accept (and call claim) shows one twist, ticked; an FIB leader sees all three. (P15)
- [ ] Happy hour cash max 1.25, sergeant sets x1.2 and starts a happy hour: a SAST unit without the sergeant completes a run, the card shows "x1.20 happy hour" and pays x1.2; a run accepted after the hour pays x1. A raised twist cash never pays above twistMaxCash. (P16)
- [ ] Type of the Day: pick Patrol, the screen says it counts tomorrow, a second pick the same day is refused; after the daily reset SAST sees Patrol as Type of the Day with double points; FIB and the sergeant keep the server's type. (P18)
- [ ] Push a chosen mission: Live Missions -> Page a unit, pick Patrol, a SAST unit and a mission: the leader gets "Command pushed you a mission", only that unit sees it on Dispatch; Claim starts it, Decline ends it and tells the sergeant. FIB units and his own unit are refused; the sixth push of the day is refused. (P19)
- [ ] Happy hour points max 1.25, set x1.2: the card shows "Happy hour x1.2" and points are x1.2; none after the hour; twist points together never exceed twistMaxPoints. (P20)
- [ ] Department goals: pick one daily and two weekly goals with a reason: the line says it counts from next week, Home goals do not change this week; after the weekly reset SAST goals come only from the pick (+50 / +200); FIB and the sergeant still get any goal. (P21)
- [ ] Give points: Department Report -> a SAST officer -> Give points 30 with a reason: manual award toast, Profile history entry, audit "Manual award (supervisor)"; no button for FIB or his own or alt character; 80 more the same day refused (100 a day). (P22)

## Admin UI and Settings

- [ ] The Admin sidebar shows the headings NPC missions, Police teamwork, Pay and rewards and Server (Player vs police while live crimes or volunteers are on); every screen still opens; groupByPlay = false brings the old order back. (AP1)
- [ ] config.lua opens with PART 1 · GENERAL and its six parts follow the Admin UI; Settings -> All settings lists the sections in that order, with Run limits (Config.Limits) under Server; a mission desk still shows for its department after a department's jobs change in Settings. (AP2)
- [ ] config.lua opens with CONTENTS (the six parts and their blocks) and every PART heading has a "Usually changed here:" line; Settings -> All settings shows a description on every setting, also Bonuses -> lab_fire -> value, Markers -> kinds -> clue -> scale, Departments -> fib -> jobs and a Builder range such as Blocks -> pursuit -> speed. The server behaves as before (no value changed). (G8)
- [ ] Settings -> Features lists the features by section; turning "Runners tire" off asks nothing and shows Off at once; turning Live crimes on asks first; Cash for live cases switches on with one click; Cash.allowManualCash still wants ENABLE; each change is in Settings -> History and the audit log; Settings opens that setting in All settings. (AP1)
- [ ] /CrimsonPoliceAdmin lands on Home with Live now and six tiles; each tile opens the right screen; Something wrong? lines open Missions, Permissions, System, Payments. Landing = 'payouts' in Settings: Payouts opens first. (A3)
- [ ] Sidebar shows 5 items + More (8); a stuck payment shows its count on More while folded; More stays open after reopening; groupSidebar off gives one flat list. (A2)
- [ ] Settings opens in Simple (about 25 plain settings, no Config paths); "All settings" shows everything by section; search "tweaks" shows Open Missions; settingsView = 'all' opens on All settings. (A7, A8)
- [ ] Settings: click "Built-in mission tweaks" near the bottom and its settings are in view; Tablet and commands shows "Default tablet key" and "Players may open the tablet with a key"; labels read plainly (e.g. "Seconds a runner sprints"). (A1, A7)
- [ ] Plain labels in Economy -> Payouts dialog, the Builder blocks and publish steps, Settings badges and filter, Officers record and disputes, Leaderboards award. (A9)
- [ ] Missions -> Gang Shootout opens one drawer; switch a location off and set a new payout with a reason: the catalog has one location fewer and Payouts -> Missions shows the amount. (A10)
- [ ] Home -> Give or take points 50 with a reason: the toast names the officer and points move; 600 asks for the citizen ID. Turn missions on or off (type "beat"), Change pay (Patrol), Quick settings ("debug") all work; homeForms = false makes the tiles only open screens. (A11)
- [ ] Payouts -> Set payout -> Event chip fills the reason; Home's points form has the same chips; a built-in's Quick edit time limit 20 shows 20:00. (A12)
- [ ] Start a mission while a unit member is already on a run: Live -> Refused shows "A unit member is already on a mission."; Home -> Something wrong? shows Refused starts today: 1 and opens the tab. (A4, A5)
- [ ] Put a broken custom mission (e.g. timeLimit = 5) in missions/custom and press Reload mission files: it shows greyed "Not loaded" with "Time limit must be 1 to 60 minutes."; Show the problem gives the file and the loader's text. (A6)
- [ ] Admin -> Departments -> FIB -> Edit -> Officer options -> HUD side -> Allowed: No: an FIB officer's My options no longer shows HUD side. (O12)
- [ ] Admin -> Officers -> an officer with changed options -> Look lists them; Reset options with a reason empties the list, he gets a notice and My options shows defaults. (O12)
- [ ] Departments -> SAST -> Officer options -> Auto-Ready Allowed: Yes; a SAST officer turns it on; 50 m from the leader he is Ready at once ("Auto-Ready: you are Ready") and can still press Not ready; 500 m away he is asked as before. (O13)
- [ ] Permissions -> Mission controls row on; Mission cooldowns Lowest 0.5 / Highest 1.0, Save; a supervisor's change shows value, who and when; Reset with a reason; a grant (SAST from grade 4) under "Who may use them" works. (P4)
- [ ] Settings -> Real suspects: the AFK and custody options name their unit. (C14)
- [ ] Settings -> Testing lists the test-panel key (Config.Testing.panelKey, ships F7) as a restart setting; F7 still opens the panel for an admin who never rebound it. (K22)
- [ ] Audit -> Export (and Export part) and Payments -> Export of thousands of rows: the tablet keeps answering while the file loads (Config.Limits.exportBps). (K17)
- [ ] With Config.Limits.netRateResponse = 'kick', click Audit -> Load part a few times quickly as admin: you are not dropped or reported; normal clicking never refuses anything with the shipped 'block'. (K10, Checkpoint)
- [ ] Normal officer and sergeant use leaves no "sent admin-only" lines in System -> Problems. (K9)
- [ ] Bulk void of a few thousand rows with Corrections open: the bar moves about twice a second, the row ends as done with Undo, no error banner. (Q21)
- [ ] System -> Back up now on a big server: no long freeze; the daily backup does not hold up the weekly and monthly resets. (Q15)
- [ ] Files mode with a year of runs: Run clean-up now gives no multi-second freeze or console hitch, the archived counts match. (Q14)
- [ ] Missions -> Builder shows the same list; the server profiler no longer shows a ~40 ms builder:list block every 30 s. (Q9)

## Mission Builder

- [ ] Supervisor UI -> Mission Builder -> New mission -> Beat patrol at the Vespucci car park: Use my position names it "Beat patrol - <street>"; place or record the checkpoints, Next, Next, Publish, confirm in under 10 clicks; the full editor shows the same draft. (B14)
- [ ] Gang shootout in the wizard: Fill the points for me places hostile spawns outside the arrival circle. (B14, B10)
- [ ] Admin Home -> Make a new mission, Missions -> New mission and New mission in the Builder tab all open the wizard; Config.Builder.quickWizard = false opens the old dialog. (B15)
- [ ] A new patrol with one location publishes and plays; the Locations step shows the 3-or-more tip; a built-in cut to 2 locations is refused. (B1)
- [ ] Add "Field contact": real card name, description and objective name; shootout spawns too close to the start give one error naming "Hostile spawn points". (B2)
- [ ] Record a short driven beat (under 0.8 km, ending where it began): saved as checkpoints, publishes. (B3)
- [ ] "Grove Street Beat" publishes as custom_grove_street_beat.lua, test tier Reinforced; Scaling and Test show "(optional)"; after Publish or leaving by the sidebar another supervisor opens it without a lock. (B4)
- [ ] Placement tool: X cancels without change; aim at a point (turns red) and Delete removes only that one; the HUD keep-out matches the red circle round the start. (B5)
- [ ] Locations step: "Set start here" sets the start and keeps the tablet open; "Add here" in a car uses the car's spot and heading; in water or a no-build zone it shows why and sets nothing. (B6)
- [ ] Point list: Delete the 3rd spawn removes only it; Set here on the 2nd moves it and keeps it 2nd; GPS on a row sets a waypoint. (B7)
- [ ] As admin, Gang Shootout location 3 -> Teleport on the start lands you on the ground and audits builderTeleport; a supervisor with no grant has no Teleport button. (B8)
- [ ] Permissions -> Builder teleport: SAST from grade 4, Save (audited): a grade-4 SAST supervisor sees Teleport, grade 3 does not; Off removes it again. (B9)
- [ ] Shootout draft: "Fill 11 for me" shows 11 dashed rings outside the arrival circle; Keep places them on safe ground; Try again proposes others; Place by hand opens the tool; 300 m away it says to stand near the location. (B10)
- [ ] Duplicate a built-in, Move start 1 km away: points left behind are listed and Publish fails with "points are up to ... from the start"; Move them too, check heights, save, Publish works. (B11)
- [ ] Duplicate Gang Shootout, Move the whole location here in your own yard: the start and spawns move together on the ground; any spawn in a wall or water is listed and can be refilled or placed by hand; Publish works. (B12)
- [ ] Block settings for a Gang shootout show Waves, Enemies per wave, Weapons, Difficulty and a closed "More settings"; Hard raises aim, armour and health; Details folds the rest. (B16)
- [ ] Copy Drug Lab Raid -> Show on map: the pause map shows dots at the cabin, none in the sea; gone after reopening the tablet; "All locations" shows one dot per start. (B17)
- [ ] Test-drive a long custom route and run Check spawn points over all missions: Crimson-Police resmon drops, no hitch, Stop still works. (Q22)
- [ ] Two admins: the second sees the first's lock; autosave keeps the lock over a few minutes; breaking the lock stops the first editor's autosave with the locked message. (Q23)
- [ ] Builder: a point inside the west prison yard and a point inside Fort Zancudo are refused as no-build zones. (L5, L7)

## Missions and blocks

- [ ] Stolen Vehicle Takedown with a partner 1 km away when the car flees: the partner has the red car blip and a yellow line; neither loses it while the car is 500 m or more away. (M3)
- [ ] Armored Truck Escort: 300 m from the truck your line goes to the truck; next to it, to the destination flag. (M3)
- [ ] Traffic Enforcement: no blip on the violator until it has passed you. (M3)
- [ ] Prison Break with a partner 500 m away: orange inmate blips at the radar edge and a line to the nearest, still there during an escape countdown. (M4)
- [ ] Warrant Service: line to the front door, then after the knock to the suspect (orange while running, red if he fights or gives up); objective 6 is a yellow "Scene" pin without a skull. (M4, M6)
- [ ] Hostage Rescue objective 2: blue blips on the tied hostages, then a green "Safe point" flag once one is freed. (M4)
- [ ] Parking Patrol: every car to check is a yellow car blip, also before it appears; parked cars 250 m away show at the radar edge. (M4, M7)
- [ ] Gang Shootout: a red skull circle "Hostiles" with a line to its centre that turns off inside. (M5)
- [ ] Manhunt: a yellow "Search area (600 m)" circle and pin; inside, the line goes to the nearest numbered clue; the circle shrinks after each clue; a fugitive who runs is orange with the line on him. (M5)
- [ ] Beat Patrol with a late partner: start line only while he drives there, then a yellow line to the numbered checkpoint; his own map waypoint turns that line off. (M6)
- [ ] Bomb Disposal: a "Search area" circle, then numbered device blips with a line to the nearest. Business Check: the line to the next door stays steady while your partner checks his. (M6)
- [ ] Drug Lab Raid objective 5: the lab blip says "Shut down the lab"; after two misses it turns orange "Ventilate 1" and flashes (Config.Markers.setbackFlash) with its line, then yellow again. (M6, M7)
- [ ] Gang Hideout Raid: hostile dots at the radar edge from far; the lieutenant's is bigger and named "The lieutenant". (M7)
- [ ] Pursuit Sim: the driver who bails is orange, red once he stops or gives up. (M7)
- [ ] Impound / Arrest on a stop: the tow truck and prisoner transport are blue blips while they drive in and go when they leave. (M7)
- [ ] Force Radio Silence in a test run: Business Check shows one door, no line; Gang Shootout the circle only, no hostile dots. Settings -> Map markers -> Radio Silence 'full' brings them back; 'none' shows nothing. (M8)
- [ ] Settings -> Events -> twists: switch one off and it is no longer offered. (M8b)
- [ ] Two officers, Stolen Vehicle Takedown, the second leaves late: "Your partners have started", he follows the car's line, is not abandoned for leaving the start route, arrives within 150 m. (M11)
- [ ] The late partner gets Config.Route.followActionSeconds (300 s) to reach the action; "Joining your partners" and the run bar show the seconds left in the last 2 minutes. (R6)
- [ ] In a Field Contact, a contact who gives up shrinks to the surrendered blip size (0.6), the same near and far. (R6, R7)
- [ ] Two back-to-back runs with cuffing and a tired runner: poses and walk styles still play in the second. (K16)
- [ ] Frisk, talk, run plate, knock, clue search, hostage cut and defuse bars all work; a Ventilate bar stops at once when the objective ends. (K13)
- [ ] Gang Shootout major tier with 4-6 officers: waves arrive as before, no LOS probe bursts in resmon while the cap is full. (Q11)
- [ ] Two officers, the non-host right behind the suspect car: suspects flee and fight, blips and the aim-to-surrender hold respond about every 250 ms, no resmon spikes when the car changes owner. (Q12)
- [ ] Debug on, officer B by a witness for 60 s: the phone animation does not restart; hostages kneel, follow to the safe point and cower as before. (Q13)
- [ ] During a course or search: HUD texts change at the same moments as before; a rename in Settings -> Names shows within 250 ms. (Q18)
- [ ] Traffic stop: hold the eye on the driver door and compare resmon; the contact key by the transport van with an escorted person picks the same van, no hitch. (Q20)
- [ ] Suspicious Activity at LSIA: GPS ends on the ground road next to the car, not the flyover; at Paleto on the logging track with the car in sight. (L2)
- [ ] Spawn-point check then play Parking Patrol #7: cars at the kerb by the meters on Bay City Avenue. (L3)
- [ ] Traffic Enforcement #3 (Bay City Incline) and #4: the observed car drives 80-105 km/h, not 140; Admin UI -> Missions shows the new labels; a location switched off by its old label stays off. (L4)
- [ ] Check spawn points and play Drug Lab Raid "Site office, Davis Quartz" and Gang Hideout Raid "Projects, Rancho" (ground height, walls, start on the road). (L7)
- [ ] Two simultaneous runs never share a spot (only if you can run two at once on one strip, e.g. Banham Canyon). (L6)

## Real suspects (ships off)

- [ ] With Config.LiveCrime.enabled and Config.Volunteers.enabled off as shipped, nothing changes for officers and idle resmon is unchanged. (V1, V3, V4, V5, V6)
- [ ] A database server creates the empty table cp_pvp_pairs on start. (V7)
- [ ] A database server creates the empty table cp_pvp_cases on start. With live crimes or volunteers on, close a case, restart Crimson-Police: Admin UI → Real suspects → Cases still lists it with its timeline and damage ledger. Give a volunteer a strike (say yes, then cancel), restart: his /crimsonheat menu still shows the strike, and he must volunteer again. (F1)
- [ ] With live crimes on: Admin UI → Real suspects → Pairs and blocks shows "Name (CITIZENID)" for officers and suspects, also for an offline player; Block pair someone, then Lift it with a reason: it leaves the list, the pair can take a case together again, the audit log has the lift, and a restart does not bring it back. Shoot a suspect with a Combat Pistol: the case's damage ledger reads Combat Pistol, not a number. With volunteers on, give a volunteer a strike, then Volunteers tab → Clear strikes with a reason: his /crimsonheat menu shows no strike. (F2)
- [ ] Tase a fleeing Warrant Service suspect: he gives up as before and nothing goes to the Review Queue; tell the developers if run details often show "A stun was reported that the server did not see" for real taser hits. (V2)
- [ ] Tase a fleeing real suspect in Flee & Arrest or Pursuit: he gives up at once and no stun_unproven note appears in the run detail. (R7)
- [ ] Optional: with Config.NpcCombat.playerHitDropsProtection = true, an officer on an NPC mission shot by a player takes normal headshot damage until the run ends; shipped false, no change. (V8)
- [ ] Crimson-Contracts guards keep their own damage while an officer is on a run nearby (the crimsonPoliceRun bag). (V8)
- [ ] Config.RealSuspects (officerAlerts, routeEnds, downed, downedPickupDelay) and Config.LiveCrime.requireRoute show in Settings; nothing changes until a live case exists. (V9, V10)
- [ ] As shipped, the Admin UI has no Real suspects screen. With Config.LiveCrime.enabled = true (reopen the Admin UI), More -> Real suspects lists the cases; a case opens its timeline and damage ledger; your own case is greyed; Block pair, Exclude and Suspend need days and a reason, then show under Pairs and blocks and in the audit log. (V18)
- [ ] As shipped, /crimsonheat does nothing. With Config.Volunteers.enabled = true (restart, or turn it on in Settings), a civilian types /crimsonheat: the rules alert, then the suspects to play; he gets "You volunteer as a suspect for 60 minutes". /crimsonheat again shows the menu (time left, Renew, Change, Stop). An on-duty officer is refused; going on police duty, logging out or Stop ends it. (V20)
- [ ] As shipped (every Config.Volunteers mode 'npc') the Mission Board has no "Real suspect" badge and accepting works as before. With enabled = true and Config.Volunteers.modes.investigation = 'players_only', Admin UI -> Permissions -> Config health warns that no Investigation mission has a suspect a volunteer can play (until the slot steps) and the Investigation card is locked "No volunteer suspect is free". (V21)
- [ ] As shipped nobody is ever asked to play a suspect. Once a built-in mission offers a volunteer slot (V23-V25), with enabled = true and its type set to 'players_when_available': a listed civilian gets the "Play a suspect now?" pop-up after a unit accepts with Real suspect OK; No (or waiting 30 s) asks the next volunteer and costs no strike; Yes sets his waypoint, the officers get "A volunteer plays this mission's suspect", reaching the waypoint says "You are in position", an officer within 100 m makes the case engaged (Real suspects screen timeline), /crimsonheat shows Cancel this case, and when the mission ends he is told he is free to go. Not reaching the waypoint in 5 minutes is a strike and the NPC plays the suspect. (V22)
- [ ] Warrant Service with a volunteer (Config.Volunteers.enabled = true, modes.investigation = 'players_when_available', Real suspect OK ticked): while he is asked nobody waits at the door and the HUD says "Stand by"; once he said yes no NPC suspect and no armed associate appear, the knock says "Real suspect: the wanted person is a real player", the map pointer stays on the door, and cuffing him (detained) completes the first step. Cuffing him while he is AFK ends the mission (Abandoned, his strike); a no-show before officers reach him brings the NPC back at the door. (V23)
- [ ] Street Race Bust with a volunteer driver (Config.Volunteers.enabled = true, modes.patrol = 'players_when_available', Real suspect OK ticked, the volunteer ticked the driver role): while he is asked no racer appears and the HUD says "Stand by: a real suspect may drive"; after his yes no NPC racer appears (driverNpcCars false), the map pointer is the first grid slot, and once he is in position the pointer jumps to "Suspect vehicle: last reported" every 30 s (never between), the HUD says "Real suspect: a real player drives the suspect vehicle"; detaining him completes the race. With driverNpcCars = true two NPC racers race beside him. He gets away (lost): the mission fails. (V24)
- [ ] Manhunt with a volunteer fugitive (Config.Volunteers.enabled = true, modes.investigation = 'players_when_available', Real suspect OK ticked, the volunteer ticked the fugitive role): while he is asked no fugitive appears and the HUD says "Stand by: a real suspect may play the fugitive"; after his yes no NPC fugitive appears, he has the search circle as a red circle on his map, officers see only the circle and the clues; checking a clue shrinks the circle around him (his map circle shrinks too). Leaving the circle warns him; staying out 30 s ends his part (a strike, Real suspects timeline "stayed outside the search area"). Detaining him completes the search. (V25)
- [ ] LIVE call (Config.LiveCrime.enabled = true, Crimson-Contracts with ContractsConfig.LifecycleEvents = true): start a Warehouse Burglary with a second account as the crew and trigger its police alert: Dispatch shows a red LIVE card (LIVE-001, the alert's title and street, the area, "2 suspects", never where they are) and idle officers get a red toast; it lapses after 300 s or when the contract ends. An admin test contract never makes one. (V11)
- [ ] Claim the LIVE call as a unit leader: the case opens at once at the reported place (no draw, no twists, no ready check as shipped); the HUD shows Respond to the reported scene, Secure the scene (60 s inside 75 m) and Detain and book the suspects; the crime's own sc-dispatch call does not end it. (V12, V14)
- [ ] During the case the map shows the reported scene and, after securing it, one "last reported" point per free suspect that moves only every 60 s; the tablet's Live case card says how old the points are and when the next comes, never a suspect's state or live position. (V12, V16)
- [ ] Cuff the suspect with sc-police and keep him cuffed 30 s: a detain line on the result; cuff one who is down: half a detain line; book him at Mission Row (jail 5+ months): a booking line. End case from the radial menu: the result card says "Live case: the lines below are the points", lists each suspect's outcome by label, and pays no cash. (V12, V13, V16)
- [ ] Backup: a second officer on no mission who marks himself responding to the crime's sc-dispatch call, or reaches the scene, gets "Join the live case?" for 30 s; Yes joins him (only lines after his join count). (V15)
- [ ] Admin UI -> Real suspects shows the case with its timeline (claim, responded, scene secured, contact, cuffed, detained, end case), the damage ledger and the flags; shoot an unarmed suspect: the officer's run is flagged rs_unarmed_shot. (V17, V18)
- [ ] With a test script listening (AddEventHandler 'crimson-police:server:liveCrimeEnded'), the end of a live case prints the crime's uid and each suspect's outcome by citizenid, with no position; `exports['Crimson-Police']:GetAvailablePolice()` answers the idle on-duty officers (nil while live crimes are off). (V19)
- [ ] A volunteer mission ends: a script listening to 'crimson-police:server:volunteerEnded' gets his citizenid, the suspect he played and his outcome; Admin UI -> Real suspects -> Cases filter Volunteers shows the case (the suspect played, the mode, where the match got to), and the Volunteers tab lists who volunteers now with their strikes. (V26)
- [ ] Surrender in a live case (Config.LiveCrime.enabled = true): as the suspect type /surrender with an officer of the case within 50 m: a Surrender pop-up; Yes tells the officers "Suspect A has surrendered: cuff them". Cuff him and hold 30 s: the result has the Peaceful arrest line. Walk 10 m away, draw a weapon or wait 120 s uncuffed: the surrender ends and both sides are told. As an officer within 15 m of a free suspect you get "close enough to talk down" once; radial Talk them down gives the suspect "An officer is talking you down" (No: the officer is told, nothing else changes). Admin UI -> Real suspects timeline shows talk_down, surrendered (with the officer's name), peaceful_arrest. With enabled = false /surrender does nothing and the radial item is missing. Resmon idle stays at 0.02 ms or less. (RP1)
- [ ] Owner walk-through: follow README 9.16.1 (Owner checklist) on a test server, share README 9.16.2 (Rules for cases with real suspects) with officers and players, then set both switches back to false: nothing new starts and idle resmon stays at 0.02 ms or less. (V27)

- [ ] Criminal tablet: `Config.Volunteers.enabled` and `Config.CriminalTablet.enabled` on; a civilian types `/crimtab`: the dark tablet opens on Home; agree, tick a suspect, Get on the list: the time left shows. An officer on duty types `/crimtab`: refused. (G2)
- [ ] With the criminal tablet open, officers take a mission a volunteer can play: Jobs shows the suspect, type, area and timer (no pop-up); Accept sets the waypoint and Active shows the meet point and time left; Give up within a minute is free (no strike in History). Close the tablet while a question is open: the pop-up comes up for the seconds left. (G2)
- [ ] `access = 'granted'`: Admin UI → Permissions → Extra grants → Criminal tablet for one gang from a grade: only its members open `/crimtab`; the grant gives no Supervisor UI button. Resmon of Crimson-Police with the tablet closed stays at 0.02 ms or less. (G2)

## Feature rewards (G3)

- [ ] Shipped: Admin UI → Settings → Features → Money lists Pay volunteer suspects, Pay talk-downs, Pay field training sign-offs, Pay finished field training and Pay supervisor point awards, all Off, each with its money, account and items buttons and the Item rewards switch. Nothing is paid by any of them while Off. (G3)
- [ ] Live-case cash and volunteer-case cash switch on with one click (no typed ENABLE); Cash.allowManualCash still asks for ENABLE. (G3)
- [ ] Pay volunteer suspects On, account cash: a volunteer escapes officers who reached him: he gets $1500 cash and Admin UI → Payments shows "Suspect pay (volunteer case)"; a no-show, a cancel, an AFK catch or a test run pays nothing; the same case never pays twice. (G3)
- [ ] Account item with moneyItem black_money (an item in your ox_inventory): the volunteer gets 1500 black_money instead of cash; a full inventory leaves the payment pending until his next login. (G3)
- [ ] Settings → FeatureRewards.surrender.items: an unknown item name or a weapon is refused; `{ { item = 'water', count = 1 } }` is saved, and with Item rewards On the officer who talks a suspect down gets the water once per suspect. (G3)
- [ ] Field training On and Pay field training sign-offs On: each sign-off pays the trainer $250 once; the last one pays the rookie $1000 once. Give points On: 10 points pay the officer $50 (at most $2500). (G3)
- [ ] Rewards screen (H1): shipped, the Admin UI has no Rewards screen. `Config.AdminUi.rewardsScreen` On in Settings: Admin UI → Rewards lists Patrol, Training, Investigation and Tactical (payout, Paid as, item pool), Live cases and Volunteer cases (officers), Volunteer suspects, Talk-downs, Field training sign-offs, Finished field training and Supervisor point awards. Change a payout: Settings → History and the Activity log show it. (H1)
- [ ] Rewards screen: with Item rewards Off, the top card says Off and **Turn item rewards on** turns it on in one click; each Items block then loses its "Item rewards are off" badge. (H1)
- [ ] Rewards screen → Volunteer suspects: the item picker lists only your ox_inventory items; saving `water` x1 works, a weapon is refused. Money by mission type: Investigation Got away $2000 → a volunteer who escapes an Investigation case gets $2000, a Patrol case still pays $1500; the criminal tablet's Jobs card shows $2,000 for an Investigation job. (H1)

## Every workflow end to end (G7)

- [ ] Admin only: an officer who sends a setting change gets refused; the admin turns on Volunteers, Volunteers → modes (Investigation: players when available), the criminal tablet (Features), access Granted and Pay volunteer suspects in Settings, each at once, no restart. (G7)
- [ ] Permissions → Extra grants → Criminal tablet for Ballas from grade 1: a Ballas grade 1 member opens `/crimtab`; a civilian outside the gang is refused; an officer on duty is refused. (G7)
- [ ] The Ballas member gets on the list from Home; a unit accepts Investigation with Real suspect OK: Jobs shows the job with its Reward line "$1,500 if you get away, $500 if you are caught" and no position. Accept, travel, the unit reaches him (Active: giving up is no longer free), he runs and the unit gives the mission up: he is paid $1,500 cash once, History shows "got away" and no strike. (G7)
- [ ] Live control → anti-farm → Clear cooldowns for both officers, and Settings → Real suspects: Job hop minutes and Suspect cooldown 0: the same unit and volunteer play again at once. He accepts, the unit waits at the start, after 60 s he presses Give up: one strike in History, Active empty, nothing paid. (G7)

## Every workflow end to end, part 2: officers and supervisors (H7)

- [ ] Settings: Item rewards On with a Patrol pool, Mission controls On, Give points On, Your controls today On, Give points money On. An officer plays Beat Patrol to the end: the result screen shows $250 and the item; the bank and the inventory get them once. (H7)
- [ ] A SAST trooper and an FIB agent in one unit play Gang Shootout: each row is Reinforced with two departments, each is paid $920 and gets the item. (H7)
- [ ] A sergeant creates a Patrol call on Dispatch; a trooper claims it, a second trooper is refused; the run pays as a normal Patrol. (H7)
- [ ] The sergeant clears a trooper's Beat Patrol cooldown (he can take it again), sets the hourly cap inside the admin's bounds (Your controls today shows it), gives 20 points ($100 and the item once; an FIB sergeant and his own character are refused) and commends him. (H7)
- [ ] A flagged run keeps its cash and items until a supervisor of its department approves it; a voided run keeps them until the officer's dispute is approved. (H7)

## Every workflow end to end, part 3: live crime, surrender, field training, restarts (H8)

- [ ] Settings: Live crimes On, Live-case cash On, Item rewards On, Pay talk-downs On with water x1, Field training On, Tasks `{ "tactical": 1 }` (saved: leaving the other types out is allowed now), Trainer bonus 10, Pay field training sign-offs and Pay finished field training On. (H8)
- [ ] A crew of two does a Warehouse Burglary: the LIVE card shows "2 suspects"; a unit claims it, secures the scene; a third officer reaching the scene gets "Join the live case?" and joins. Cuff A 30 s (detained), book him at Mission Row for 10 months (booked). The third officer gets "close enough to talk down", Talk them down, B says Yes, cuff him 30 s: Peaceful arrest, and that officer gets $300 and the water once. End case: three rows, each paid the Investigation pay once. Admin UI → Real suspects lists the case; its timeline has joined, talk down, surrendered, peaceful arrest and end case. (H8)
- [ ] Claim a second crime, get a suspect to surrender, then `restart Crimson-Police` before anyone cuffs him: no officer is on a case, no row, no pay, no cooldown, no LIVE call; Settings changes are kept; the first case is still on Real suspects with its timeline; `/surrender` says he is not wanted. Form the unit again: the next crime posts a LIVE call and pays as usual. (H8)
- [ ] Field training: an officer cannot pair; a sergeant pairs a cadet with a trainer. Start Gang Shootout as their unit and restart: the run did not count and the pairing is kept. Play it again to the end: the trainer gets the "ready" toast. Restart again: Profile → Field training still shows the task ready. Another supervisor cannot sign off; the trainer can: the cadet gets the Field Training badge, the trainer $250 and 10 points, the cadet $1000. A further restart pays nothing twice. (H8)

## Supervisor screens inside (H4)

- [ ] Mission controls and Review Queue show their name, subtitle and one help line; each Mission controls group card has its own line under the title. (H4)
- [ ] Mission controls: Department notices shows Post a notice and Running now (n); End asks for a second click. Department Report: Field training shows Pairings (n). (H4)
- [ ] `Config.Tablet.supervisorControlsCard = true`: Department Report shows Your controls today; give 10 points to an officer, open Department Report again: the Give points row is up by 10; a control the admin switches off leaves the card. Shipped `false`: no card. (H4)

## Admin screens merged and faster (H6)

- [ ] Shipped config: the Admin UI sidebar still shows Payouts and Payments, every list pages as before. (H6)
- [ ] `Config.AdminUi.moneyScreen` On in Settings, reopen the Admin UI: one Money screen with Mission pay and Payments made tabs; the Home Change pay tile opens Mission pay; Leaderboards → stuck payments opens Payments made filtered to Paying; the Payments badge sits on Money. (H6)
- [ ] `Config.AdminUi.pageSize = 10`: Activity log, Payments made and Officers show 10 rows a page; an officer with more than 10 runs on Leaderboards shows a pager under his runs; Player suspects cases page by 10. (H6)
- [ ] `Config.AdminUi.oneRequest` On: Payments made shows its totals cards and Leaderboards its flagged runs as before; with Config.Debug on, opening each screen logs one request. (H6)

## Admin Home Needs attention and plain titles (H5)

- [ ] Shipped config: Admin UI Home looks as before (no Needs attention panel); every screen title is as before. (H5)
- [ ] `Config.AdminUi.needsAttention` On in Settings: Home shows Needs attention on top with Problems, Refused starts today, Open disputes, Flagged runs waiting for review and (with live crimes or volunteers on) Open player suspect cases. File a dispute from an officer: Open disputes goes to 1 within a minute; click it: Officers opens on Disputes. Click Problems: Server health opens on Problems. (H5)
- [ ] `Config.AdminUi.plainLayout` On: the title inside Live reads "Running now", Payouts "Mission pay", Permissions "Who can do what"; Off: "Live", "Payouts", "Permissions". (H5)

## Restarts and logout

- [ ] Start the server: the console shows the database or saves folder at version 11 (10 after O1, 11 after P1). (O1, P1)
- [ ] After a restart, mission cooldowns, the abandon cooldown, board locks, the hourly and daily caps and mission calls behave exactly as before. (P2, P3)
- [ ] Nothing to test in game for run ids: runs started before and after a restart simply never share an id. (K11)
- [ ] Mark responding to a real sc-dispatch call, switch character: the new character is not "On a call" and can accept missions. (K12)
- [ ] `restart Crimson-Police` from txAdmin during an admin test teleport or the first fade of Check spawn points: the screen comes back and the ped is not frozen. (K14)
- [ ] /logout during a spawn check ends the check: the new character is not moved to the old spot or unfrozen by it. (K14)
- [ ] With an officer on a mission that gives items, `restart ox_inventory`; a second later dropping or giving a mission item is refused. (C14)
- [ ] Relog with My options set: the tablet look and text size apply before the tablet is opened. (O5)

## Final review fixes (X11)

- [ ] Mission ban: sergeant A bans a SAST trooper for 24 h; sergeant B (a higher grade than the trooper) tries a 1 h ban on him: refused with "already has a mission ban from another supervisor", and B still has no Lift; A may change his own ban; an admin may replace or lift it. (X11)
- [ ] Give points: a supervisor at 90 of 100 today double-clicks Give points 50 on two officers at once: one is given, the other says "Please wait a moment" or is refused by the daily limit; never 190 in a day. (X11)
- [ ] Give points as an admin without a police job: Department Report offers Give points for any officer, and the officer's department switch and min / max apply (switch the control off for FIB only: refused for an FIB officer, given for a SAST one). (X11)
- [ ] My options: tick a Favourite type and press that group's Reset within half a second: the option stays at its default after a few seconds and after reopening the tablet. (X11)
- [ ] Failed start (for example the database user without CREATE): the console shows the failure lines once and no "happyhour: check failed: err.not_started" every 30 s afterwards. (X11)

## Bug sweep fixes (Z1)

- [ ] Feature rewards on (suspect): start an admin backup (maintenance lock) and let a volunteer case end fairly meanwhile: his row shows Pending in Payments made, and he is paid when the backup ends or at his next login (never lost as a duplicate). (Z1)
- [ ] Live crimes with backup on: an officer joins a live case, quits the game and reconnects while it runs: he gets no join offer and "You left this live case and can't join it again"; Live shows one entry for him. (Z1)
- [ ] Volunteers on: a volunteer with a police job plays a case, officers reach him, he goes on duty: he is told his part is void with a strike, the staff timeline shows "went on police duty mid-case", the criminal tablet History shows "Went on police duty (strike)". (Z1)
- [ ] Volunteers on: while a volunteer plays a case, turn Volunteers off in Settings: his criminal tablet still gives the case up with Give up (no "no case"). (Z1)
- [ ] Volunteers on: many quick runs while volunteers are asked; end one run right as it asks; the same volunteer is still asked by the next run (no restart needed). (Z1)
- [ ] `Config.Volunteers.endEvent = false`: a volunteer plays a case to the end: his criminal tablet History still shows the case. (Z1)
- [ ] Field training with ftoSignOff pay on: trainer A signs Patrol for rookie R and is paid; unpair R, pair him with trainer B (or pair a finished R again), B signs Patrol: B is not paid again for that task. (Z1)

## Bug sweep fixes (Z2)

- [ ] Review rules: set SAST's reviewRules adminOnlyKinds to rs_linked_accounts; a SAST row flagged with it and disputed by its officer does not show in a SAST supervisor's Disputes, and Approve through the dispute answers "The department hands this kind of flag to admins only"; an admin still approves it. (Z2)
- [ ] Feature rewards on (suspect): a volunteer is reached by officers, then the officer quits (or takes a real call, or an admin cancels the run): the volunteer gets no suspect pay and Payments made shows no row for him. (Z2)
- [ ] Feature rewards on (suspect and surrender): an officer and a volunteer on the same PC or connection (identityMatch.flag): the officer's row is flagged rs_linked_accounts, and neither the volunteer's suspect pay nor a talk-down pay is made for that run. (Z2)
- [ ] Config.Volunteers.voidRun = 'keep_earned': an engaged volunteer gives up right after contact: the officers' result shows only the lines earned (no base points, no Fast finish, no mission cash). (Z2)
- [ ] Volunteers on: an engaged volunteer is downed and respawns at a hospital before the death timer: he gets a strike and "You respawned at a hospital before the death timer ran out", the staff timeline shows the early-respawn line, and his criminal tablet History shows "Respawned before the death timer (strike)". (Z2)
- [ ] Criminal tablet: say yes to a case and keep Active open: "Giving up now is free" switches to the strike text by itself once cancelGraceSeconds (60 s) have passed. (Z2)
- [ ] Live crime with one officer: detain the suspect, then get downed (RealSuspects.downed = 'keep_earned'): the run ends Completed, and a second live case on the same suspect inside pairCooldownHours does not score again for that pair. (Z2)
- [ ] FeatureRewards account = 'item': a row left in Paying is paid by Pay again as the money item (not "Qbox refused"); Clawback on such a row answers "This payment was a money item ..." and takes nothing. (Z2)
- [ ] Auto-Ready allowed and on: join a unit, stand at the keys, the leader accepts a type: you are Ready at once. Turn Auto-Ready off in My options: the next ready check asks you; on again: answered after you move. (LP1)
- [ ] Criminal tablet: close it with Escape twice in a row (open, Escape, open, Escape quickly): the pause menu never opens, and Escape opens it normally a second later. (LP1)
- [ ] Search Area, Device Check, Interact Points: the markers show near each clue, device and point as before. Testing debug drawing still draws the test area. (LP1)

## FiveM semantics fixes (Z4)

- [ ] Search Area or Flee and Arrest: drive more than 400 m away from the suspect (or let every officer leave its
  area) for a minute, then come back: the suspect is still there and alive, the run goes on (no "vanished; counted
  as dead" in the server console). A parked contact car stays too. (Z4)
- [ ] Unit of 2, ready check: let the countdown reach 0 and press Ready right after: "Not every unit member answered
  the ready check in time" shows, no mission starts, the leader sees the timeout cancel at once. (Z4)
- [ ] Settings → Performance → pushGapMs `500`: start a ready check and decline it: the banner goes away (no stale
  Yes/No). Two admins in the Mission Builder: break the lock of a mission the other edits: he is told. Back to `0`.
  (Z4)
- [ ] Criminal tablet open: an admin opens the Admin UI (`client:openAdmin`), then closes it: the criminal tablet is
  closed, not left on screen without a cursor. Open it, then log out to character select: it closes. Open it, get
  downed: it closes; using the item while down says "You can't use the tablet while you are down." (Z4)
- [ ] Auto-Ready on: go off duty and back on duty within a second, join a unit, stand at the keys: the first ready
  check is answered for you. (Z4)
- [ ] Settings → Performance → loopScale `4`: a checkpoint route without medals (Beat Patrol), drive fast at a
  checkpoint from far away: it counts on the first pass. On foot far away resmon stays as before. Back to `1`. (Z4)
- [ ] EVOC course: put the course car in a garage (or `/dv`) mid-course and take another car: no "vehicle
  undriveable" fail and no contact from a stranger car. (Z4)
- [ ] Volunteer search: say yes, let an officer drive up to you within the first minute, then press Cancel this
  case: it is a strike. Cancel within the first minute with no officer near: no strike, as before. (Z4)

## Resmon (OP1)

- [ ] No run, tablet closed, Config.Debug off: resmon shows Crimson-Police at 0.00-0.01 ms on the client.
- [ ] EVOC course run: drive through a checkpoint too fast ("Stop inside" shows), stop, hold, cross: the HUD line and
  the markers behave as before; resmon stays below what it showed before the update.
- [ ] Foot chase with a tired runner (Config.Flee on): he jogs, then walks, and is let go when he surrenders or gets
  into a car, as before.
- [ ] My options -> Sounds -> objective cues off: no cue plays; on again: the next cue plays.

## Server cost and NUI (OP2)

- [ ] Open the Admin UI the first time after a restart: Home shows within a moment, the sidebar at once; every other
  screen opens as before, and every screen looks as it did (colours, spacing, buttons).
- [ ] Supervisor UI → Mission Builder and `/crimtab` (criminal tablet): open and look as before.
- [ ] Suspend an officer from the Admin UI: his tablet refuses him within 15 s, as before; unsuspend: it opens again.
  Retire and unretire: the same.
- [ ] Mute mission calls on your Profile: no call pop-up; pick favourite types in My options → Dispatch: only those
  pop up.
- [ ] An admin leaves mid logo upload (Departments → Upload a logo): whoever joins next with his id can upload at
  once.
- [ ] Settings → Performance → pushGapMs `250`: in a unit run the tablet's run bar and Unit screen still follow every
  change (at most a quarter second later). Back to `0`.
- [ ] Settings → Performance → latentAboveBytes `65536`: Leaderboard, Mission Board and the Admin lists still load
  (a big one may take a moment longer); the rest of the tablet keeps answering meanwhile. Back to `0`.
- [ ] Server resmon of Crimson-Police with officers on duty and no run: at or below what it showed before the update.

## Known leftovers fixed (R1)

- [ ] `Config.AdminUi.needsAttention` On: Home's Something wrong? shows Last mission load, Config health and stuck
  payments only (Problems and Refused starts are on the Needs attention panel); Off: all five lines as before. (R1)
- [ ] `Config.Tablet.supervisorControlsCard` On: a sergeant gives points or sets a Mission ban; Your controls today
  shows the new count of today at once, without reopening Department Report. (R1)
- [ ] `Config.AdminUi.pageSize` 10 with more than 10 player suspect cases: Real suspects -> Cases -> Open lists the
  open cases from every page (the pager counts only those). (R1)
- [ ] `Config.CriminalTablet.enabled` true and `item = 'no_such_item'`: Permissions -> Config health shows a warning and
  the console prints one line at start; a real item shows an ok line. (R1)
- [ ] Officer tablet -> Department Challenge: the same header (title, one line of help, a refresh button) and the same
  loading and error lines as the other officer screens. (R1)
- [ ] Defuse a device in a search-then-defuse mission after its prop was removed: the prop comes back at the device's
  own spot and the device is worked there, never at another object. (R1)
