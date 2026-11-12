# In-game checklist

What to check in game on a test server, one section per feature. The id in brackets at the end of a line
names the change it came with.

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
- [ ] Set Config.CrossDept.readyCheck = true (Settings -> Ready check). Launch, join with a SAST and an FIB officer, Start now: both get the ready prompt (the ready key works, Auto-Ready does not); both Ready starts the run; a Not ready takes that officer off the join list and joining opens again. (FM8)
- [ ] Set Config.CrossDept.invites and Config.CrossDept.memberList = true (Settings -> Cross-department operations). Launch, join with a SAST officer: the Unit screen's operation card lists him and an invite picker; invite an FIB officer: he hears the invite tone, gets a toast and an invite card on his Unit screen; Accept puts him on the join list (both see two members), Decline tells the inviter, Withdraw closes it; after Start now the open invites are gone. (FIN7)
- [ ] One money engine: complete a mission (bank pay), turn on a feature reward with account 'item' and moneyItem black_money (Settings -> Feature rewards) and let it pay, and turn on Cash.allowManualCash and pay an officer 100: each shows one row in Admin UI -> Payments, the mission and manual pay arrive in the bank, the feature reward as the item; an offline officer's payment waits as Pending and is paid at login. (FM11)
- [ ] At 1080p, 1440p and another UI scale, open the citation offence picker, the Leaderboard filters, Profile and an Admin Settings dropdown: the list opens inside the tablet, arrows / Home / End / Enter / typing work, Escape closes the list first, a click outside closes it, the value saves. (K23)
- [ ] Leave the route during a run with the tablet closed: the off-route warning pulses three times and then stays highlighted; live dots in the tablet do the same. (K18)
- [ ] Fill an officer's inventory to the weight limit and accept a custom mission that gives an item: "no room" toast, no item, the run starts; no orphan is logged at the end. (K7)
- [ ] With Config.Tablet.access.requireItem = true, an officer without the tablet item away from a station desk cannot accept a mission or claim a call; at the desk he opened the tablet at he still can. (K8)
- [ ] Open and close the tablet during a run: sidebar badges and Dispatch look the same on reopen; the run bar updates at once on each objective change. (Q16, Q17)
- [ ] My options: tick a Favourite type and press that group's Reset within half a second: the option stays at its default after a few seconds and after reopening the tablet. (X11)
- [ ] Failed start (for example the database user without CREATE): the console shows the failure lines once and no "happyhour: check failed: err.not_started" every 30 s afterwards. (X11)
- [ ] Field training with ftoSignOff pay on: trainer A signs Patrol for rookie R and is paid; unpair R, pair him with trainer B (or pair a finished R again), B signs Patrol: B is not paid again for that task. (Z1)
- [ ] Criminal tablet: say yes to a case and keep Active open: "Giving up now is free" switches to the strike text by itself once cancelGraceSeconds (60 s) have passed. (Z2)
- [ ] Auto-Ready allowed and on: join a unit, stand at the keys, the leader accepts a type: you are Ready at once. Turn Auto-Ready off in My options: the next ready check asks you; on again: answered after you move. (LP1)
- [ ] Criminal tablet: close it with Escape twice in a row (open, Escape, open, Escape quickly): the pause menu never opens, and Escape opens it normally a second later. (LP1)
- [ ] Auto-Ready on: go off duty and back on duty within a second, join a unit, stand at the keys: the first ready
  check is answered for you. (Z4)
- [ ] Volunteer search: say yes, let an officer drive up to you within the first minute, then press Cancel this
  case: it is a strike. Cancel within the first minute with no officer near: no strike, as before. (Z4)
- [ ] My options -> Sounds -> objective cues off: no cue plays; on again: the next cue plays.
- [ ] Restart once: the server log shows "applied migration 017_lookup_indexes.sql" (database or saves folder), then
  Crimson-Police at version 18.
- [ ] Officer tablet -> Department Challenge: the same header (title, one line of help, a refresh button) and the same
  loading and error lines as the other officer screens. (R1)
- [ ] Dispatch open: a call claimed by another unit updates within about a second. A HUD countdown steps once a
  second and ends on time.

## One look on every tablet

- [ ] Open every screen of the officer tablet, the Supervisor UI and the Admin UI: each shows its name, then one
  short line of help under it, with the same spacing, cards, tables and buttons on every screen. Admin Money and
  Supervisor Department show the line on each tab. (UI1)
- [ ] `/crimtab` (criminal tablet on): the dark street look stays (acid green, typewriter font, square corners);
  every screen shows its name and one line of help; History lists the cases in a table with When, Mission, Suspect and
  Outcome; Stop volunteering and Give up still take two clicks. (UI1)
- [ ] Supervisor Department -> Training: End training still takes two clicks. Admin Payments, Officers, Leaderboards
  and Real suspects: the page buttons under the lists work as before. (UI1)

## Officer UI with fewer screens

- [ ] Open the officer tablet: the sidebar shows Home, Mission Board, Dispatch, Unit, Active Mission, Me and My
  options. Home opens on your status (Ready for a mission), your next goal with its count and a big Find a mission
  button that opens the Mission Board; with today's goal done it names this week's. (UI5)
- [ ] Me: Profile & History, Leaderboard and Department Challenge are three tabs; a commendation puts its badge on
  Me. Click a leaderboard row: that officer's profile opens on the Profile tab; Back opens the Leaderboard tab; a
  challenge contributor opens his profile too; Edit profile, Hide my name and disputes work as before. (UI5)
- [ ] Start Beat Patrol: Home's button reads Back to your mission and opens Active Mission. The bar over every
  screen opens Active Mission and has Mission Board, Dispatch and Unit links (Dispatch gone with mission calls off;
  no link to the screen you are on). (UI5)

## Settings inside each screen, presets

- [ ] Admin UI -> Money: the gear at the top right opens Settings for Money with only Cash, Payout editing, Item
  rewards and Feature rewards; change Cash.dailyCap there and Save: the toast shows, Settings -> History lists the
  change and the Activity log has it; Cash.allowManualCash still asks for ENABLE. Search "cap" in the panel: only
  matching rows show. All settings opens the full Settings screen. Home, Map markers and Player suspects have their
  own gear; Settings has none. (UI6)
- [ ] Settings -> Presets: Go-live -> Preview lists Debug, Allow teleport and Debug overlay with Now On and After Off
  (the reason for pay changes counted as already set); Apply: the toast says 3 settings changed, Debug shows Changed,
  the Activity log has three Setting changed lines with the reason "Preset: Go-live" and one Settings preset applied
  line. Preview again: nothing to change. Reset Debug: it is on again. Casual and Serious RP preview their own
  changes; no preset lists an admin, permission, money or webhook setting. (UI6)

## Admin UI by job, one search

- [ ] Admin UI: the sidebar shows Home, then People (Officers, Departments, Who can do what; Leaderboards and Seasons
  under More), Missions (Missions, Running now, Map markers, Test tools), Real players (Player suspects), Money,
  Review (Review, Activity log) and System (Settings, Server health). With live crimes and volunteers off, the Real
  players group is not shown. (UI2)
- [ ] Press Ctrl+K anywhere in the Admin UI: the cursor goes to the search. Type `builder`: Missions › Mission Builder
  opens the Builder tab. Type part of an officer's name: he is listed under Officers and a click opens his record.
  Type part of a mission's name: a click opens its drawer on the list. Type `pageSize`: the setting is listed and opens
  Settings on it; the last line Search settings for "..." still works. (UI2)
- [ ] Review -> Flagged runs: Approve and Void ask for a reason and the row leaves the list; a run with two flagged
  rows has Approve all. Review -> Profiles, Disputes and Corrections work as the old Officers tabs did (Undo on a
  correction, a dispute row opens the officer). Home's Open disputes and Flagged runs lines open the right Review tab;
  Leaderboards no longer lists flagged runs. The Review badge counts the profiles waiting and the open disputes. (UI2)

## Supervisor

- [ ] As a SAST sergeant (master switch off, as shipped): Supervisor -> Mission controls is in the sidebar; Mission cooldowns -> Tactical x0.5, Save with a reason: the row shows "Changed by" and the change wait counts down. (P5)
- [ ] Cooldowns are server-wide: a SAST and an FIB officer's Gang Shootout lock are both 10 min instead of 20; the sergeant himself keeps 20. An FIB sergeant sees the same values and can put them Back to config with a reason. (P5)
- [ ] With every Config.MissionControls.controls.*.on = false and the master switch off, the screen is gone after reopening the tablet. (P5)
- [ ] Start a 15-minute happy hour: a SAST officer takes Beat Patrol twice in a row; Home and the Mission Board banner count down and name the sergeant; the sergeant still has his cooldown and the banner says so; a second happy hour the same day is refused. (P6)
- [ ] Admin UI -> Live shows the happy-hour chip; End now brings the cooldowns back at once. (P6)
- [ ] Admin UI -> Permissions -> Mission controls -> Happy hour: set Highest cooldown scale 1. Supervisor UI -> Mission
  controls shows a Cooldowns x slider; start 10 minutes at x0.5: the officer banner reads "mission cooldowns x0.5",
  a 20-minute mission cooldown shows 10 minutes, the sergeant keeps his 20. Set Starts a day 0: a supervisor's Start
  is refused. (FM10)
- [ ] Department Report -> a SAST officer with a Gang Shootout cooldown -> Clear cooldown with a reason: he gets a toast and his card unlocks. (P7)
- [ ] With "+ minutes" switched on, press "+ minutes", 2 on a live SAST run: the participants are told and the HUD timer gains two minutes. (P7)
- [ ] Time to reach the start: set SAST to 900 s: a SAST-led unit's HUD shows 15:00 after accept, an FIB-led unit still 10:00. (P8)
- [ ] NPC difficulty 'easy' for SAST: Gang Shootout hostiles go down faster for a SAST-led unit, result points the same as 'normal'. Largest unit 3: a SAST leader's fourth invite is refused. (P9)
- [ ] Mission types on the board: switch Tactical off for SAST: SAST sees it locked "Off for SAST by command", FIB can accept it. Recommend Patrol: it shows right after a SAST officer's favourites with "Recommended by command". (P10)
- [ ] Mission ban: ban a SAST trooper for 1 h from Department Report: toast, "Mission ban until <time> (by <you>)" with every card locked, call claim and Cross-Department join refused. Admin -> Officers -> him -> Today & cooldowns -> Lift ban opens his board at once. (P11)
- [ ] Department call lane every 120-240 s, Patrol only: SAST officers get "SAST call" Patrol calls every 2-4 minutes, FIB never sees them, the sergeant's own unit cannot claim them. (P12)
- [ ] Department notices: a notice posted in Supervisor UI -> Department -> Calls & notices shows on SAST Home under Announcements, not for FIB. (P13)
- [ ] Notices (FM6): the staff notices card (Leaderboards -> Recognition) and the department card are the same card with Post a notice, Running now and History; the admin ends a SAST department notice from his card (with a reason) and it moves to History on both. With `Notices.department.alert = 'sound'` a SAST officer on duty gets a toast with a tone when a SAST notice is posted, a FIB officer gets nothing.
- [ ] Cross-Department participation, opt SAST out, launch a Cross-Department Mission: SAST boards show the operation but Join says the department opted out. (P13)
- [ ] Leaderboard visibility = callsigns only: an FIB officer's Leaderboard shows SAST officers by callsign. (P14)
- [ ] Review rules -> "A Void needs a second supervisor": one SAST sergeant's Void shows "Void pending" and the row stays; a second SAST sergeant's Void voids it. (P14)
- [ ] Twists offered: offer only Time Crunch, pre-ticked: a SAST leader's accept (and call claim) shows one twist, ticked; an FIB leader sees all three. (P15)
- [ ] Happy hour cash max 1.25, sergeant sets x1.2 and starts a happy hour: a SAST unit without the sergeant completes a run, the card shows "x1.20 happy hour" and pays x1.2; a run accepted after the hour pays x1. A raised twist cash never pays above twistMaxCash. (P16)
- [ ] Type of the Day: pick Patrol, the screen says it counts tomorrow, a second pick the same day is refused; after the daily reset SAST sees Patrol as Type of the Day with double points; FIB and the sergeant keep the server's type. (P18)
- [ ] One dispatch flow: Department -> Calls & notices has one **New call** button. Every unit + Patrol posts an open call every unit sees on Dispatch; a unit picked pages it (only that unit for 30 s, then everyone); a unit and a mission pushes that mission. Claim and Decline on Dispatch, the server's own calls and a department lane call all show on the same Dispatch list. Settings -> Mission calls lists laneMaxOpen (2) and pushPerDay (5) with the other call limits. (FM7)
- [ ] Finish notifications and dispatch (FIN6): an admin ends a staff notice with a reason; History on his card shows "Ended early ... by <his name>" and "Reason: ...". Set `MissionCalls.pageDecline = true` in Settings, page a SAST unit: its leader sees **Decline** on the card; Decline ends the page, another unit can claim the call at once and the sergeant gets "the unit declined the page". With it off (shipped) a page has no Decline. A LIVE call still shows red on Dispatch and pops up for idle units. Settings -> Dispatch (mission calls) lists the real-call numbers (dodgeWindow 60, respondingExpiry 1200) and the backstop radius and delay (300, 1).
- [ ] Push a chosen mission: Department -> Calls & notices -> New call, pick Patrol, a SAST unit and a mission: the leader gets "Command pushed you a mission", only that unit sees it on Dispatch; Claim starts it, Decline ends it and tells the sergeant. FIB units and his own unit are refused; the sixth push of the day is refused. (P19)
- [ ] Happy hour points max 1.25, set x1.2: the card shows "Happy hour x1.2" and points are x1.2; none after the hour; twist points together never exceed twistMaxPoints. (P20)
- [ ] Department goals: pick one daily and two weekly goals with a reason: the line says it counts from next week, Home goals do not change this week; after the weekly reset SAST goals come only from the pick (+50 / +200); FIB and the sergeant still get any goal. (P21)
- [ ] Give points: Department Report -> a SAST officer -> Give points 30 with a reason: manual award toast, Profile history entry, audit "Manual award (supervisor)"; no button for FIB or his own or alt character; 80 more the same day refused (100 a day). (P22)
- [ ] One Review queue (FM3): Supervisor UI -> Department -> Review -> Queue lists the department's flagged runs and
  disputes in one table with a Type column; All / Flagged runs / Disputes filter it, each with its count. Approve or
  Void a flagged run and Approve or Reject a dispute (a reason each time): the row leaves at once, and a second
  supervisor of the department with the queue open sees it go. Under reviewRules.secondVoid a first Void says it
  waits. Admin UI -> Review -> Queue lists every department (the admin-only flag kinds and failed-run disputes too),
  has Approve all on a run with two flagged rows and Open the officer on a failed-run dispute (award its points
  there). Home's Flagged runs and Open disputes lines open the queue on that type. (FM3)
- [ ] Supervisor UI shows **Department** (no Department Report, Mission controls or Review Queue entries) with the tabs Officers, Controls, Review, Calls & notices and Training; the Review Queue count sits on Department; Live Missions has no Mission calls panel (it is on Calls & notices). A supervisor with `missionCalls` off and no Mission control open has no Calls & notices tab; an officer an admin granted only field training sees Department with Training alone. `supervisorLanding = 'review'` opens Department on Review. A value saved earlier for Tablet.supervisorControlsCard gives no console line. (MG3)
- [ ] Department shows Today at a glance over the tabs: On duty matches the department's officers on duty, Runs going matches Live Missions (a click opens it), Waiting for review matches the Department badge (amber while above 0, a click opens Review), Your controls used today goes up after a Give points (a click opens Controls). An officer granted only field training sees no tiles. Officers -> click an officer: one side panel from the right with his runs and commendations and the buttons Give points, Mission ban (Lift for your own ban), Clear cooldown, Commend and Field training as you may use them; each opens its form in the panel and the toast, the audit row and the limits are as before; no button on your own row. Field training: a rookie in training shows his progress and End training, an officer not in training gets Pair trainer, a trainer gets a rookie. (UI4)
- [ ] Mission controls and Review Queue show their name, subtitle and one help line; each Mission controls group card has its own line under the title. (H4)
- [ ] Mission controls: Department notices shows Post a notice, Running now (n) and History; End asks for a second click. Department Report: Field training shows Pairings (n). (H4)
- [ ] Department notices with two running: click End on A, End on B, End on A again; A stays armed ("click again") for the full 3 seconds and the next click ends it. (H6)
- [ ] Admin UI: with exactly one entry, Audit shows "1 entry"; with one change the Setup wizard says "Finish (1 change)"; one problem line on Settings / Permissions reads "1 line needs a look"; a mission with one load warning says "1 warning". (H6)
- [ ] Department -> Controls shows each control's admin limits (and today's use where it has a day count) on its row, and the Give points / Mission ban card below; give 10 points to an officer: the Give points row is up by 10; a control the admin switches off leaves the list. (H4, MG3)
- [ ] Mission ban: sergeant A bans a SAST trooper for 24 h; sergeant B (a higher grade than the trooper) tries a 1 h ban on him: refused with "already has a mission ban from another supervisor", and B still has no Lift; A may change his own ban; an admin may replace or lift it. (X11)
- [ ] Give points: a supervisor at 90 of 100 today double-clicks Give points 50 on two officers at once: one is given, the other says "Please wait a moment" or is refused by the daily limit; never 190 in a day. (X11)
- [ ] Give points as an admin without a police job: Department Report offers Give points for any officer, and the officer's department switch and min / max apply (switch the control off for FIB only: refused for an FIB officer, given for a SAST one). (X11)
- [ ] Review rules: set SAST's reviewRules adminOnlyKinds to rs_linked_accounts; a SAST row flagged with it and disputed by its officer does not show in a SAST supervisor's Disputes, and Approve through the dispute answers "The department hands this kind of flag to admins only"; an admin still approves it. (Z2)
- [ ] A supervisor starts a 1-minute happy hour: about a minute later (within 30 s) the screens show it ended and
  cooldowns count again. Restart the resource during one: it still ends. (LP3)
- [ ] Admin UI → Runs and Leaderboards flagged runs, a supervisor's per-day capped action (Mission ban), an
  auto-suspension after voided runs: all behave as before.
- [ ] A sergeant gives points or sets a Mission ban; Department -> Controls shows the new count of today at once,
  without reopening it. (R1)
- [ ] A supervisor one below `missionBanPerDay` (or the clear-cooldown or add-run-time cap) clicks twice very fast on
  two officers: one goes through, the other says Please wait a moment; the day's count never passes the cap. (Z5)

## Admin UI and Settings

- [ ] The Admin sidebar shows the headings NPC missions, Police teamwork, Pay and rewards and Server (Player vs police while live crimes or volunteers are on); every screen still opens. (AP1)
- [ ] config.lua opens with PART 1 · GENERAL and its six parts follow the Admin UI; Settings -> All settings lists the sections in that order, with Run limits (Config.Limits) under Server; a mission desk still shows for its department after a department's jobs change in Settings. (AP2)
- [ ] config.lua opens with CONTENTS (the six parts and their blocks) and every PART heading has a "Usually changed here:" line; Settings -> All settings shows a description on every setting, also Bonuses -> lab_fire -> value, Markers -> kinds -> clue -> scale, Departments -> fib -> jobs and a Builder range such as Blocks -> pursuit -> speed. The server behaves as before (no value changed). (G8)
- [ ] Settings -> Features lists the features by section; turning "Runners tire" off asks nothing and shows Off at once; turning Live crimes on asks first; Cash for live cases switches on with one click; Cash.allowManualCash still wants ENABLE; each change is in Settings -> History and the audit log; Settings opens that setting in All settings. (AP1)
- [ ] /CrimsonPoliceAdmin lands on Home with Live now, Alerts and five shortcuts; each shortcut opens the right screen; the Config health and mission load alerts open Permissions and Missions, Stuck payments opens Money → Payments. (A3, UI3)
- [ ] The Admin sidebar folds Seasons, Leaderboards, Departments, Audit and Testing under More; a link to one of them unfolds More; More stays open after reopening. (A2)
- [ ] Settings opens in Simple (about 25 plain settings, no Config paths); "All settings" shows everything by section; search "tweaks" shows Open Missions. (A7, A8)
- [ ] Settings: click "Built-in mission tweaks" near the bottom and its settings are in view; Tablet and commands shows "Default tablet key" and "Players may open the tablet with a key"; labels read plainly (e.g. "Seconds a runner sprints"). (A1, A7)
- [ ] Plain labels in Economy -> Payouts dialog, the Builder blocks and publish steps, Settings badges and filter, Officers record and disputes, Leaderboards award. (A9)
- [ ] Missions -> Gang Shootout opens one drawer; switch a location off and set a new payout with a reason: the catalog has one location fewer and Payouts -> Missions shows the amount. (A10)
- [ ] Home -> Give or take points 50 with a reason: the toast names the officer and points move; 600 asks for the citizen ID. Turn missions on or off (type "beat"), Change pay (Patrol), Quick settings ("debug") all work. (A11)
- [ ] Payouts -> Set payout -> Event chip fills the reason; Home's points form has the same chips; a built-in's Quick edit time limit 20 shows 20:00. (A12)
- [ ] Start a mission while a unit member is already on a run: Live -> Refused shows "A unit member is already on a mission."; Home -> Alerts shows Refused starts today: 1 and opens the tab. (A4, A5)
- [ ] Put a broken custom mission (e.g. timeLimit = 5) in missions/custom and press Reload mission files: it shows greyed "Not loaded" with "Time limit must be 1 to 60 minutes."; Show the problem gives the file and the loader's text. (A6)
- [ ] Admin -> Departments -> FIB -> Edit -> Officer options -> HUD side -> Allowed: No: an FIB officer's My options no longer shows HUD side. (O12)
- [ ] Admin -> Officers -> an officer with changed options -> Look lists them; Reset options with a reason empties the list, he gets a notice and My options shows defaults. (O12)
- [ ] Departments -> SAST -> Officer options -> Auto-Ready Allowed: Yes; a SAST officer turns it on; 50 m from the leader he is Ready at once ("Auto-Ready: you are Ready") and can still press Not ready; 500 m away he is asked as before. (O13)
- [ ] Permissions -> Mission controls row on; Mission cooldowns Lowest 0.5 / Highest 1.0, Save; a supervisor's change shows value, who and when; Reset with a reason; a grant (SAST from grade 4) under "Who may use them" works. (P4)
- [ ] Settings -> Real players: the AFK and custody options name their unit. (C14)
- [ ] Settings -> Testing lists the test-panel key (Config.Testing.panelKey, ships F7) as a restart setting; F7 still opens the panel for an admin who never rebound it. (K22)
- [ ] Audit -> Export (and Export part) and Payments -> Export of thousands of rows: the tablet keeps answering while the file loads (Config.Limits.exportBps). (K17)
- [ ] With Config.Limits.netRateResponse = 'kick', click Audit -> Load part a few times quickly as admin: you are not dropped or reported; normal clicking never refuses anything with the shipped 'block'. (K10, Checkpoint)
- [ ] Normal officer and sergeant use leaves no "sent admin-only" lines in System -> Problems. (K9)
- [ ] Bulk void of a few thousand rows with Corrections open: the bar moves about twice a second, the row ends as done with Undo, no error banner. (Q21)
- [ ] System -> Back up now on a big server: no long freeze; the daily backup does not hold up the weekly and monthly resets. (Q15)
- [ ] Files mode with a year of runs: System → Jobs → Clean-up → Run now gives no multi-second freeze or console hitch, the archived counts match. (Q14)
- [ ] Missions -> Builder shows the same list; the server profiler no longer shows a ~40 ms builder:list block every 30 s. (Q9)
- [ ] Shipped config: every list pages as before. (H6)
- [ ] Admin UI: one Money screen (no Payouts, Rewards or Payments in the sidebar) with Pay rates, Rewards, Payments and Department funds tabs; the Home Change pay tile opens Pay rates; Leaderboards → stuck payments opens Payments filtered to Paying; the Payments badge sits on Money; the sidebar search finds Money by typing Payouts or Rewards. (MG2)
- [ ] Money tabs (MG2): Pay rates sets and clears a payout (reason asked, Activity log row); Rewards saves a change (Settings → History); Payments' row actions and the money tools that ship off show only with their switch on, as before; Department funds shows each department's Funds card, and Add funds still asks for its confirm. (MG2)
- [ ] `Config.AdminUi.pageSize = 10`: Activity log, Payments made and Officers show 10 rows a page; an officer with more than 10 runs on Leaderboards shows a pager under his runs; Player suspects cases page by 10. (H6)
- [ ] Payments made shows its totals cards and Leaderboards its flagged runs; with Config.Debug on, opening each screen logs one request. (H6, BK1)
- [ ] The title inside Live reads "Running now", Money → Pay rates "Mission pay", Permissions "Who can do what". (H5, BK1)
- [ ] Suspend an officer from the Admin UI: his tablet refuses him within 15 s, as before; unsuspend: it opens again.
  Retire and unretire: the same.
- [ ] An admin leaves mid logo upload (Departments → Upload a logo): whoever joins next with his id can upload at
  once.
- [ ] Settings: type in the search box with a few hundred settings showing: the text follows your typing without lag;
  saving one setting still updates its row.
- [ ] Home's Alerts show Problems, Refused starts today, Config health warnings and Missions the last load refused;
  Live now shows Stuck payments. (R1, BK1, UI3)

## Mission Builder

- [ ] Supervisor UI -> Mission Builder -> New mission -> Beat patrol at the Vespucci car park: Use my position names it "Beat patrol - <street>"; place or record the checkpoints, Next, Next, Publish, confirm in under 10 clicks; the full editor shows the same draft. (B14)
- [ ] Gang shootout in the wizard: Fill the points for me places hostile spawns outside the arrival circle. (B14, B10)
- [ ] Admin Home -> Make a new mission, Missions -> New mission and New mission in the Builder tab all open the wizard; its Open the full editor on the first step opens the New mission dialog. (B15, BK1)
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
- [ ] Search Area, Device Check, Interact Points: the markers show near each clue, device and point as before. Testing debug drawing still draws the test area. (LP1)
- [ ] Search Area or Flee and Arrest: drive more than 400 m away from the suspect (or let every officer leave its
  area) for a minute, then come back: the suspect is still there and alive, the run goes on (no "vanished; counted
  as dead" in the server console). A parked contact car stays too. (Z4)
- [ ] Unit of 2, ready check: let the countdown reach 0 and press Ready right after: "Not every unit member answered
  the ready check in time" shows, no mission starts, the leader sees the timeout cancel at once. (Z4)
- [ ] Tablet open at a desk: walk away, it closes within about a second; open it from the item with
  `requireItem` on, drop the item: it closes within a few seconds; open it and get downed: it closes. (LP3)
- [ ] EVOC course: put the course car in a garage (or `/dv`) mid-course and take another car: no "vehicle
  undriveable" fail and no contact from a stranger car. (Z4)
- [ ] Mute mission calls on your Profile: no call pop-up; pick favourite types in My options → Dispatch: only those
  pop up.
- [ ] Stand at a mission desk on duty: Open Crimson-Police shows; go off duty: it hides at once (at most a second);
  back on duty: it shows. In Crimson-Arena: hidden.
- [ ] `Config.RealPlayers.criminalTablet.enabled` true and `item = 'no_such_item'`: Permissions -> Config health shows a warning and
  the console prints one line at start; a real item shows an ok line. (R1)
- [ ] Defuse a device in a search-then-defuse mission after its prop was removed: the prop comes back at the device's
  own spot and the device is worked there, never at another object. (R1)
- [ ] Host and a partner chase a route fleer (or fight a hostile ped); the partner stays closest for over 10 s, then
  the host gets close again and OneSync gives the ped back: within about 2 s the ped runs his route (or fights)
  again on the host's game, he never stands idle. (Z6)
- [ ] Testing: invite an officer, start a test: the debug stream and the invitation expiry work; a unit's invite
  still expires after 120 s; `jobRecheck`: go off duty during a run, you leave it within `jobRecheck` seconds.

## Mission desks from the Qbox duty points

On a station with the normal game interior (docs/OWNER_GUIDE.md 3.2). Stand at the desk on duty and look at it.

- [ ] Mission Row PD front desk moved (441.20, -978.90) -> (441.00, -977.30, 30.69), 2.5 m from the qbx_policejob duty point: "Open Crimson-Police" shows at the front counter, the box is not inside a wall, and the duty point and trash still work. (LOC2)
- [ ] Paleto Bay sheriff front desk (new) at (-448.55, 6011.92, 31.82), 1.6 m from the qbx_policejob duty point: "Open Crimson-Police" shows inside the lobby, not outside or in a wall, and the duty point still works. (LOC2)

## Mission locations and other scripts

Points moved so they stay clear of other public scripts' places (docs/OWNER_GUIDE.md 4.1): Bomb Disposal spots 2 m from the
store registers, safes and shop counter, Hostage Rescue robbers 2 m from the vault door and lockers, the warrant
suspect 2 m from the house-robbery entrance, the stolen car and one Bomb Disposal spot 6 m from a garage or taxi
marker. Run the mission on that location (turn its other locations off, docs/OWNER_GUIDE.md 2.7) and walk to the point.

- [ ] Bomb Disposal, 24/7 Supermarket, Innocence Boulevard: hiding[1] (behind the counter) at (24.51, -1349.67) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Innocence Boulevard: hiding[2] (in front of the counter) at (26.79, -1345.27) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Innocence Boulevard: hiding[3] (back room) at (28.46, -1336.95) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Innocence Boulevard: hiding[4] (back room) at (26.21, -1337.99) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Clinton Avenue: hiding[1] (behind the counter) at (371.56, 324.35) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Clinton Avenue: hiding[2] (in front of the counter) at (375.27, 327.14) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Clinton Avenue: hiding[3] (back room) at (379.92, 334.79) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Clinton Avenue: hiding[4] (back room) at (376.89, 335.33) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Palomino Freeway: hiding[1] (behind the counter) at (2559.26, 380.11) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Palomino Freeway: hiding[2] (in front of the counter) at (2554.87, 383.54) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Palomino Freeway: hiding[3] (back room) at (2547.04, 384.64) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Palomino Freeway: hiding[4] (back room) at (2548.00, 382.99) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Senora Freeway: hiding[1] (behind the counter) at (2679.77, 3277.83) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Senora Freeway: hiding[2] (in front of the counter) at (2677.62, 3282.20) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Senora Freeway: hiding[3] (back room) at (2670.39, 3286.63) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Senora Freeway: hiding[4] (back room) at (2670.99, 3288.23) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Senora Freeway (Mount Chiliad): hiding[1] (behind the counter) at (1726.53, 6413.21) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Senora Freeway (Mount Chiliad): hiding[2] (in front of the counter) at (1730.83, 6416.05) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Senora Freeway (Mount Chiliad): hiding[3] (back room) at (1736.93, 6421.54) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Senora Freeway (Mount Chiliad): hiding[4] (back room) at (1733.25, 6422.62) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Barbareno Road (Chumash): hiding[1] (behind the counter) at (-3240.08, 999.15) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Barbareno Road (Chumash): hiding[2] (in front of the counter) at (-3243.92, 1002.36) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Barbareno Road (Chumash): hiding[3] (back room) at (-3251.97, 1003.13) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Barbareno Road (Chumash): hiding[4] (back room) at (-3252.37, 1004.79) is inside on the floor, not in a wall. (LOC1)
- [ ] Bomb Disposal, 24/7 Supermarket, Barbareno Road (Chumash): hiding[7] (outside by the entrance) at (-3237.15, 1005.48) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Legion Square: spawns[3] (back office) at (147.43, -1043.86) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Legion Square: spawns[4] (back office) at (152.09, -1044.40) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Hawick Avenue (Alta): spawns[3] (back office) at (311.90, -282.31) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Hawick Avenue (Alta): spawns[4] (back office) at (316.35, -282.83) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Hawick Avenue (Burton): spawns[3] (back office) at (-353.10, -53.18) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Hawick Avenue (Burton): spawns[4] (back office) at (-348.75, -53.60) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Boulevard Del Perro: spawns[3] (back office) at (-1212.18, -334.75) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Boulevard Del Perro: spawns[4] (back office) at (-1208.46, -331.67) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Great Ocean Highway: spawns[3] (back office) at (-2958.86, 481.78) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Great Ocean Highway: spawns[4] (back office) at (-2959.65, 486.12) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Route 68: spawns[3] (back office) at (1175.99, 2710.53) is inside on the floor, not in a wall. (LOC1)
- [ ] Hostage Rescue, Fleeca Bank, Route 68: spawns[4] (back office) at (1171.76, 2709.49) is inside on the floor, not in a wall. (LOC1)
- [ ] Warrant Service, Wild Oats Drive: the suspect waits on the step 2.7 m left of the door at (-177.00, 503.05), not in the bushes or the wall, and surrenders onto the step. (LOC1)
- [ ] Stolen Vehicle Takedown, Route 68 east Harmony: the stolen car spawns in the Motor Hotel car park at (1130.75, 2664.75), on the tarmac and clear of parked cars and the qbx_garages marker, and drives out onto Route 68. (LOC1)

## Real suspects (ships off)

- [ ] With Config.RealPlayers.liveCrime.enabled and Config.RealPlayers.volunteer.enabled off as shipped, nothing changes for officers and idle resmon is unchanged. (V1, V3, V4, V5, V6)
- [ ] A database server creates the empty table cp_pvp_pairs on start. (V7)
- [ ] A database server creates the empty table cp_pvp_cases on start. With live crimes or volunteers on, close a case, restart Crimson-Police: Admin UI → Real suspects → Cases still lists it with its timeline and damage ledger. Give a volunteer a strike (say yes, then cancel), restart: his /crimsonheat menu still shows the strike, and he must volunteer again. (F1)
- [ ] With live crimes on: Admin UI → Real suspects → Pairs and blocks shows "Name (CITIZENID)" for officers and suspects, also for an offline player; Block pair someone, then Lift it with a reason in Restrictions (Open Restrictions): it leaves the list, the pair can take a case together again, the audit log has the lift, and a restart does not bring it back. Shoot a suspect with a Combat Pistol: the case's damage ledger reads Combat Pistol, not a number. With volunteers on, give a volunteer a strike, then Volunteers tab → Clear strikes with a reason: his /crimsonheat menu shows no strike. (F2)
- [ ] Tase a fleeing Warrant Service suspect: he gives up as before and nothing goes to the Review Queue; tell the developers if run details often show "A stun was reported that the server did not see" for real taser hits. (V2)
- [ ] Tase a fleeing real suspect in Flee & Arrest or Pursuit: he gives up at once and no stun_unproven note appears in the run detail. (R7)
- [ ] Optional: with Config.NpcCombat.playerHitDropsProtection = true, an officer on an NPC mission shot by a player takes normal headshot damage until the run ends; shipped false, no change. (V8)
- [ ] Crimson-Contracts guards keep their own damage while an officer is on a run nearby (the crimsonPoliceRun bag). (V8)
- [ ] Config.RealPlayers (officerAlerts, routeEnds, downed, downedPickupDelay) and Config.RealPlayers.liveCrime.requireRoute show in Settings; nothing changes until a live case exists. (V9, V10)
- [ ] Settings -> All settings has one Real players section (also under the Real suspects screen's gear): the shared rules on top, then the liveCrime, volunteer and criminalTablet groups, each with its own enabled switch and the same cash, items, goals, challenge and typeOfTheDay switches; turning volunteer on leaves live crimes off and shows the Real players group in the sidebar. (FM4)
- [ ] As shipped, the Admin UI has no Real suspects screen. With Config.RealPlayers.liveCrime.enabled = true (reopen the Admin UI), More -> Real suspects lists the cases; a case opens its timeline and damage ledger; your own case is greyed; Block pair, Exclude and Suspend need days and a reason, then show under People -> Restrictions and in the audit log. (V18)
- [ ] As shipped, /crimsonheat does nothing. With Config.RealPlayers.volunteer.enabled = true (restart, or turn it on in Settings), a civilian types /crimsonheat: the rules alert, then the suspects to play; he gets "You volunteer as a suspect for 60 minutes". /crimsonheat again shows the menu (time left, Renew, Change, Stop). An on-duty officer is refused; going on police duty, logging out or Stop ends it. (V20)
- [ ] As shipped (every Config.RealPlayers.volunteer mode 'npc') the Mission Board has no "Real suspect" badge and accepting works as before. With enabled = true and Config.RealPlayers.volunteer.modes.investigation = 'players_only', Admin UI -> Permissions -> Config health warns that no Investigation mission has a suspect a volunteer can play (until the slot steps) and the Investigation card is locked "No volunteer suspect is free". (V21)
- [ ] As shipped nobody is ever asked to play a suspect. Once a built-in mission offers a volunteer slot (V23-V25), with enabled = true and its type set to 'players_when_available': a listed civilian gets the "Play a suspect now?" pop-up after a unit accepts with Real suspect OK; No (or waiting 30 s) asks the next volunteer and costs no strike; Yes sets his waypoint, the officers get "A volunteer plays this mission's suspect", reaching the waypoint says "You are in position", an officer within 100 m makes the case engaged (Real suspects screen timeline), /crimsonheat shows Cancel this case, and when the mission ends he is told he is free to go. Not reaching the waypoint in 5 minutes is a strike and the NPC plays the suspect. (V22)
- [ ] Warrant Service with a volunteer (Config.RealPlayers.volunteer.enabled = true, modes.investigation = 'players_when_available', Real suspect OK ticked): while he is asked nobody waits at the door and the HUD says "Stand by"; once he said yes no NPC suspect and no armed associate appear, the knock says "Real suspect: the wanted person is a real player", the map pointer stays on the door, and cuffing him (detained) completes the first step. Cuffing him while he is AFK ends the mission (Abandoned, his strike); a no-show before officers reach him brings the NPC back at the door. (V23)
- [ ] Street Race Bust with a volunteer driver (Config.RealPlayers.volunteer.enabled = true, modes.patrol = 'players_when_available', Real suspect OK ticked, the volunteer ticked the driver role): while he is asked no racer appears and the HUD says "Stand by: a real suspect may drive"; after his yes no NPC racer appears (driverNpcCars false), the map pointer is the first grid slot, and once he is in position the pointer jumps to "Suspect vehicle: last reported" every 30 s (never between), the HUD says "Real suspect: a real player drives the suspect vehicle"; detaining him completes the race. With driverNpcCars = true two NPC racers race beside him. He gets away (lost): the mission fails. (V24)
- [ ] Manhunt with a volunteer fugitive (Config.RealPlayers.volunteer.enabled = true, modes.investigation = 'players_when_available', Real suspect OK ticked, the volunteer ticked the fugitive role): while he is asked no fugitive appears and the HUD says "Stand by: a real suspect may play the fugitive"; after his yes no NPC fugitive appears, he has the search circle as a red circle on his map, officers see only the circle and the clues; checking a clue shrinks the circle around him (his map circle shrinks too). Leaving the circle warns him; staying out 30 s ends his part (a strike, Real suspects timeline "stayed outside the search area"). Detaining him completes the search. (V25)
- [ ] LIVE call (Config.RealPlayers.liveCrime.enabled = true, Crimson-Contracts with ContractsConfig.LifecycleEvents = true): start a Warehouse Burglary with a second account as the crew and trigger its police alert: Dispatch shows a red LIVE card (LIVE-001, the alert's title and street, the area, "2 suspects", never where they are) and idle officers get a red toast; it lapses after 300 s or when the contract ends. An admin test contract never makes one. (V11)
- [ ] Claim the LIVE call as a unit leader: the case opens at once at the reported place (no draw, no twists, no ready check as shipped); the HUD shows Respond to the reported scene, Secure the scene (60 s inside 75 m) and Detain and book the suspects; the crime's own sc-dispatch call does not end it. (V12, V14)
- [ ] During the case the map shows the reported scene and, after securing it, one "last reported" point per free suspect that moves only every 60 s; the tablet's Live case card says how old the points are and when the next comes, never a suspect's state or live position. (V12, V16)
- [ ] Cuff the suspect with sc-police and keep him cuffed 30 s: a detain line on the result; cuff one who is down: half a detain line; book him at Mission Row (jail 5+ months): a booking line. End case from the radial menu: the result card says "Live case: the lines below are the points", lists each suspect's outcome by label, and pays no cash. (V12, V13, V16)
- [ ] Backup: a second officer on no mission who marks himself responding to the crime's sc-dispatch call, or reaches the scene, gets "Join the live case?" for 30 s; Yes joins him (only lines after his join count). (V15)
- [ ] Admin UI -> Real suspects shows the case with its timeline (claim, responded, scene secured, contact, cuffed, detained, end case), the damage ledger and the flags; shoot an unarmed suspect: the officer's run is flagged rs_unarmed_shot. (V17, V18)
- [ ] With a test script listening (AddEventHandler 'crimson-police:server:liveCrimeEnded'), the end of a live case prints the crime's uid and each suspect's outcome by citizenid, with no position; `exports['Crimson-Police']:GetAvailablePolice()` answers the idle on-duty officers (nil while live crimes are off). (V19)
- [ ] A volunteer mission ends: a script listening to 'crimson-police:server:volunteerEnded' gets his citizenid, the suspect he played and his outcome; Admin UI -> Real suspects -> Cases filter Volunteers shows the case (the suspect played, the mode, where the match got to), and the Volunteers tab lists who volunteers now with their strikes. (V26)
- [ ] Surrender in a live case (Config.RealPlayers.liveCrime.enabled = true): as the suspect type /surrender with an officer of the case within 50 m: a Surrender pop-up; Yes tells the officers "Suspect A has surrendered: cuff them". Cuff him and hold 30 s: the result has the Peaceful arrest line. Walk 10 m away, draw a weapon or wait 120 s uncuffed: the surrender ends and both sides are told. As an officer within 15 m of a free suspect you get "close enough to talk down" once; radial Talk them down gives the suspect "An officer is talking you down" (No: the officer is told, nothing else changes). Admin UI -> Real suspects timeline shows talk_down, surrendered (with the officer's name), peaceful_arrest. With enabled = false /surrender does nothing and the radial item is missing. Resmon idle stays at 0.02 ms or less. (RP1)
- [ ] Owner walk-through: follow docs/OWNER_GUIDE.md 6.1 (Owner checklist) on a test server, share docs/OWNER_GUIDE.md 6.2 (Rules for cases with real suspects) with officers and players, then set both switches back to false: nothing new starts and idle resmon stays at 0.02 ms or less. (V27)
- [ ] Criminal tablet: `Config.RealPlayers.volunteer.enabled` and `Config.RealPlayers.criminalTablet.enabled` on; a civilian types `/crimtab`: the dark tablet opens on Home; agree, tick a suspect, Get on the list: the time left shows. An officer on duty types `/crimtab`: refused. (G2)
- [ ] With the criminal tablet open, officers take a mission a volunteer can play: Jobs shows the suspect, type, area and timer (no pop-up); Accept sets the waypoint and Active shows the meet point and time left; Give up within a minute is free (no strike in History). Close the tablet while a question is open: the pop-up comes up for the seconds left. (G2)
- [ ] `access = 'granted'`: Admin UI → Permissions → Extra grants → Criminal tablet for one gang from a grade: only its members open `/crimtab`; the grant gives no Supervisor UI button. Resmon of Crimson-Police with the tablet closed stays at 0.02 ms or less. (G2)
- [ ] Home's Live now shows Officers on duty (each department's count under it), Runs going with the run chips, Flagged runs to review, Profiles to review, Open disputes, Stuck payments and (with live crimes or volunteers on) Open player suspect cases. Go on duty: Officers on duty goes up within a few seconds. File a dispute from an officer: Open disputes goes to 1 within a minute; click it: Review opens on Disputes. Click Problems under Alerts: Server health opens on Problems. Set Config.AdminUi.homeShortcuts to { 'review', 'pay' } in Settings: Home shows those two shortcuts in that order. (H5, UI3)
- [ ] Feature rewards on (suspect): start an admin backup (maintenance lock) and let a volunteer case end fairly meanwhile: his row shows Pending in Payments made, and he is paid when the backup ends or at his next login (never lost as a duplicate). (Z1)
- [ ] Live crimes with backup on: an officer joins a live case, quits the game and reconnects while it runs: he gets no join offer and "You left this live case and can't join it again"; Live shows one entry for him. (Z1)
- [ ] Volunteers on: a volunteer with a police job plays a case, officers reach him, he goes on duty: he is told his part is void with a strike, the staff timeline shows "went on police duty mid-case", the criminal tablet History shows "Went on police duty (strike)". (Z1)
- [ ] Volunteers on: while a volunteer plays a case, turn Volunteers off in Settings: his criminal tablet still gives the case up with Give up (no "no case"). (Z1)
- [ ] Volunteers on: many quick runs while volunteers are asked; end one run right as it asks; the same volunteer is still asked by the next run (no restart needed). (Z1)
- [ ] `Config.RealPlayers.volunteer.endEvent = false`: a volunteer plays a case to the end: his criminal tablet History still shows the case. (Z1)
- [ ] Feature rewards on (suspect): a volunteer is reached by officers, then the officer quits (or takes a real call, or an admin cancels the run): the volunteer gets no suspect pay and Payments made shows no row for him. (Z2)
- [ ] Feature rewards on (suspect and surrender): an officer and a volunteer on the same PC or connection (antiFarm.identityMatch.flag): the officer's row is flagged rs_linked_accounts, and neither the volunteer's suspect pay nor a talk-down pay is made for that run. (Z2)
- [ ] Config.RealPlayers.volunteer.voidRun = 'keep_earned': an engaged volunteer gives up right after contact: the officers' result shows only the lines earned (no base points, no Fast finish, no mission cash). (Z2)
- [ ] Volunteers on: an engaged volunteer is downed and respawns at a hospital before the death timer: he gets a strike and "You respawned at a hospital before the death timer ran out", the staff timeline shows the early-respawn line, and his criminal tablet History shows "Respawned before the death timer (strike)". (Z2)
- [ ] Live crime with one officer: detain the suspect, then get downed (RealPlayers.downed = 'keep_earned'): the run ends Completed, and a second live case on the same suspect inside pairCooldownHours does not score again for that pair. (Z2)
- [ ] Criminal tablet open: an admin opens the Admin UI (`client:openAdmin`), then closes it: the criminal tablet is
  closed, not left on screen without a cursor. Open it, then log out to character select: it closes. Open it, get
  downed: it closes; using the item while down says "You can't use the tablet while you are down." (Z4)
- [ ] Foot chase with a tired runner (Config.Flee on): he jogs, then walks, and is let go when he surrenders or gets
  into a car, as before.
- [ ] Supervisor UI → Mission Builder and `/crimtab` (criminal tablet): open and look as before.
- [ ] `Config.AdminUi.pageSize` 10 with more than 10 player suspect cases: Real suspects -> Cases -> Open lists the
  open cases from every page (the pager counts only those). (R1)
- [ ] A volunteer is cuffed and detained, the run goes on; he presses Give up or Stop volunteering on the criminal
  tablet: the run stays In progress, the arrest stands, and Stop volunteering only ends his listing. Cuffed (not yet
  detained) and Give up: he counts as detained (left in cuffs) and the case goes on. (Z5)
- [ ] `Config.RealPlayers.volunteer.voidRun = 'keep_earned'`, a Warrant Service whose volunteer drops out after contact: the
  officers' rows have no No participant downed or No weapons fired bonus. (Z5)
- [ ] `Config.RealPlayers.onLeave = 'escaped'` (then `'caught'`) with `Config.FeatureRewards.suspect` on: an engaged
  volunteer logs off past the grace (or enters an apartment): he gets a strike, no suspect pay, and History says Left
  the case (strike); the officers' case keeps got away (or detained). (Z5)
- [ ] `voidRun = 'keep_earned'` with a players_only mission: the asked volunteer says No before any yes: the run ends
  Abandoned (no Completed row, no goal progress, no cooldown). (Z5)
- [ ] A volunteer says yes and presses Give up within `cancelGraceSeconds`: criminal tablet History shows Called off,
  not Gave up (strike). (Z5)
- [ ] Criminal tablet open, an admin uses Officers -> Support -> unstick (or F8 `CrimsonPoliceState unstick`): the
  tablet disappears with the cursor, and a later volunteer question shows its ox_lib pop-up. (Z6)
- [ ] (Dev only) A render error reaches the root boundary while the criminal tablet is open: the tablet closes with
  the cursor, Escape and keys work, and the app comes back 2 s later. (Z6)
- [ ] A volunteer's window ends; a unit draws a players_only mission a few seconds later (before the sweep): he is not
  asked, and the mission card says nobody is free. (Z6)

## Feature rewards (ships off)

- [ ] Shipped: Admin UI → Settings → Features → Money lists Pay volunteer suspects, Pay talk-downs, Pay field training sign-offs, Pay finished field training and Pay supervisor point awards, all Off, each with its money, account and items buttons and the Item rewards switch. Nothing is paid by any of them while Off. (G3)
- [ ] Live-case cash and volunteer-case cash switch on with one click (no typed ENABLE); Cash.allowManualCash still asks for ENABLE. (G3)
- [ ] Pay volunteer suspects On, account cash: a volunteer escapes officers who reached him: he gets $1500 cash and Admin UI → Payments shows "Suspect pay (volunteer case)"; a no-show, a cancel, an AFK catch or a test run pays nothing; the same case never pays twice. (G3)
- [ ] Account item with moneyItem black_money (an item in your ox_inventory): the volunteer gets 1500 black_money instead of cash; a full inventory leaves the payment pending until his next login. (G3)
- [ ] Settings → FeatureRewards.surrender.items: an unknown item name or a weapon is refused; `{ { item = 'water', count = 1 } }` is saved, and with Item rewards On the officer who talks a suspect down gets the water once per suspect. (G3)
- [ ] Field training On and Pay field training sign-offs On: each sign-off pays the trainer $250 once; the last one pays the rookie $1000 once. Give points On: 10 points pay the officer $50 (at most $2500). (G3)
- [ ] Rewards tab (H1, MG2): Admin UI → Money → Rewards lists Patrol, Training, Investigation and Tactical (payout, Paid as, item pool), Live cases and Volunteer cases (officers), Volunteer suspects, Talk-downs, Field training sign-offs, Finished field training and Supervisor point awards. Change a payout: Settings → History and the Activity log show it. (H1)
- [ ] Rewards tab: with Item rewards Off, the top card says Off and **Turn item rewards on** turns it on in one click; each Items block then loses its "Item rewards are off" badge. (H1)
- [ ] Rewards screen → Volunteer suspects: the item picker lists only your ox_inventory items; saving `water` x1 works, a weapon is refused. Money by mission type: Investigation Got away $2000 → a volunteer who escapes an Investigation case gets $2000, a Patrol case still pays $1500; the criminal tablet's Jobs card shows $2,000 for an Investigation job. (H1)
- [ ] FeatureRewards account = 'item': a row left in Paying is paid by Pay again as the money item (not "Qbox refused"); Clawback on such a row answers "This payment was a money item ..." and takes nothing. (Z2)

## Performance and loops

- [ ] Settings → Performance → pushGapMs `500`: start a ready check and decline it: the banner goes away (no stale
  Yes/No). Two admins in the Mission Builder: break the lock of a mission the other edits: he is told. Back to `0`.
  (Z4)
- [ ] Settings → Performance → loopScale `4`: a checkpoint route without medals (Beat Patrol), drive fast at a
  checkpoint from far away: it counts on the first pass. On foot far away resmon stays as before. Back to `1`. (Z4)
- [ ] Settings → Performance → markerRange `30`: drive at an escort or flee objective: its marker appears only within
  30 m; resmon while far away is lower. Back to `0`: markers at their own distance again. (LP3)
- [ ] No run, tablet closed, Config.Debug off: resmon shows Crimson-Police at 0.00-0.01 ms on the client.
- [ ] EVOC course run: drive through a checkpoint too fast ("Stop inside" shows), stop, hold, cross: the HUD line and
  the markers behave as before; resmon stays below what it showed before the update.
- [ ] Settings → Performance → pushGapMs `250`: in a unit run the tablet's run bar and Unit screen still follow every
  change (at most a quarter second later). Back to `0`.
- [ ] Settings → Performance → latentAboveBytes `65536`: Leaderboard, Mission Board and the Admin lists still load
  (a big one may take a moment longer); the rest of the tablet keeps answering meanwhile. Back to `0`.
- [ ] Server resmon of Crimson-Police with officers on duty and no run: at or below what it showed before the update.
- [ ] On a run, look at a contacted person and at a stopped car with people inside: the same Talk, Detain, Arrest,
  Frisk, Escort, seat and cuff options show as before; get into a car: they hide; get out: they show again. Client
  resmon while the eye rests on them: lower than before the update.
- [ ] Leaderboards with a long board scrolls smoothly and shows every officer in order; a Settings search for one
  letter adds rows as you scroll down.
- [ ] System → edit a department and a mission desk: the
  colours, logo and box size sit under More options; Officers → Void runs…: the mission id, Include awards and Strike
  sit under More (a ticked Strike keeps it open); Supervisor UI → Mission controls: noRepeat and the twist
  multipliers sit under More, a control you set stays open; open More, close and reopen the tablet: More is still
  open.
- [ ] Read a few errors in the Admin UI, the Mission Builder and the criminal tablet: each says what went wrong and,
  where you can do something, what to do next.
- [ ] Idle server (no run, nobody in Testing, no unit): resmon shows Crimson-Police's server side lower than before;
  start a run: the HUD timers count, the drive-to-start warning comes, custody (cuff, transport, coroner), downed
  and NPC deaths work as before; end it, start another: all of it works again.

## Restarts and logout

- [ ] Start the server: the console shows the database or saves folder at version 18 (the newest migration, 018_tours.sql). (O1, P1, OP3, TR1)
- [ ] After a restart, mission cooldowns, the abandon cooldown, board locks, the hourly and daily caps and mission calls behave exactly as before. (P2, P3)
- [ ] Nothing to test in game for run ids: runs started before and after a restart simply never share an id. (K11)
- [ ] Mark responding to a real sc-dispatch call, switch character: the new character is not "On a call" and can accept missions. (K12)
- [ ] `restart Crimson-Police` from txAdmin during an admin test teleport or the first fade of Check spawn points: the screen comes back and the ped is not frozen. (K14)
- [ ] /logout during a spawn check ends the check: the new character is not moved to the old spot or unfrozen by it. (K14)
- [ ] With an officer on a mission that gives items, `restart ox_inventory`; a second later dropping or giving a mission item is refused. (C14)
- [ ] Relog with My options set: the tablet look and text size apply before the tablet is opened. (O5)
- [ ] Open the Admin UI the first time after a restart: Home shows within a moment, the sidebar at once; every other
  screen opens as before, and every screen looks as it did (colours, spacing, buttons).
- [ ] On duty at a mission desk, `restart ox_target`: within a moment the desk offers "Open Crimson-Police" again,
  with one laptop prop (not two). (H6)
- [ ] On a Warrant Service (door), a search, an interact-point, a skill-check, a hostage or a coroner objective,
  `restart ox_target` mid-objective: Knock and announce, Check clue, the points, the devices, Cut restraints and the
  scene options come back and the objective can be finished. (H6)

## Objectives and recognition (FIN3)

- [ ] Profile: one **Recognition** card with the tabs Badges (n), Commendations (n) and, on your own profile while field training is on and you train or are trained, Field training; Sign off works from that tab. Another officer's profile shows Badges and Commendations only. (FIN3)
- [ ] Settings -> Objectives: set the daily goal reset hour to the next full hour; at that hour Home shows a new daily goal while the Type of the Day and the weekly goal stay; set it back to -1. Same for the Type of the Day reset hour (the Mission Board's x2 tag moves at that hour). (FIN3)
- [ ] Settings -> Recognition -> Kind rules `{ "valor": { "sameKindCooldownDays": 0, "crossDepartment": true } }`: a supervisor may commend valor twice in a row and to another department; teamwork still waits 7 days and stays in his department. An unknown kind is refused. (FIN3)
- [ ] The Challenge tab standings, the weekly bounty counts and Home's goal progress show the same numbers as before (one progress engine). (FIN3)

## Guided tours and the setup checklist (TR1)

- [ ] A new character opens the Officer UI: the Officer tour starts by itself. Each step rings its part of the screen
  and the card stays inside the screen at a small and a large tablet size (My options -> Tablet size). Next opens the
  Mission Board; clicking the ringed Mission Board button also moves on. The ringed buttons still work under the ring.
  The arrow keys move between steps; Escape ends the tour without closing the tablet. (TR1)
- [ ] Close and reopen: the tour starts again (Skip and Escape do not save). Finish it (Done) and reopen: it does not
  start; relog and open on another PC: still finished. The **?** in the header replays it; My options -> Tours lists
  it as Finished and starts it. (TR1)
- [ ] A supervisor: the Supervisor tour opens Department on Today, Officers, Controls, Review, Calls and Training; a
  tab he may not see is left out. From My options -> Tours, the Supervisor tour switches to the Supervisor UI. (TR1)
- [ ] An admin: the Admin tour (Home, Setup checklist, search, groups, gear, Presets, Money, Features). With
  `Config.AdminUi.setupScreen = true` and the setup not done, no tour starts; finish the setup with "Show me around"
  ticked: the Admin tour starts. (TR1)
- [ ] Admin UI -> Home -> Setup checklist on the shipped config: Storage, Presets and Debug off are open, the rest
  ticked. Apply the Go-live preset: Presets and Debug off tick on the next refresh (a minute, or reopen Home). Each
  line opens its screen. `Config.Training.setupChecklist = false`: no card. (TR1)
- [ ] The criminal tablet (`/crimtab`): its tour shows opting in, Jobs, saying yes first, Rules and History. (TR1)
- [ ] `/crimsonhelp` as an officer, a supervisor, an admin with no police job and a civilian with the criminal tablet:
  each gets his own tablet and tour; `/crimsonhelp admin` as an officer is refused with a message. (TR1)
- [ ] Admin UI -> Officers -> an officer -> Reset tours (with a reason): his next open starts the Officer tour again.
  `Config.Training.enabled = false` in Settings: no tour, no **?** button, no Tours lists. (TR1)
- [ ] resmon while a tour shows and while none does: no change while none runs (the tour looks for its element only
  while a step shows). (TR1)
- [ ] A new character's first mission run: a tip card at the top of the HUD explains the HUD, then the GPS line (on
  the way to the start), then the objectives once they show, each outlining its part and closing after 12 s. The game
  keeps full control (no mouse, no keys taken). Open the tablet over the HUD: the tip waits and comes back. (TR2)
- [ ] The run ends: the result card's tip shows. On the next run no tip shows, also on another PC. My options ->
  Tours -> First mission run tips -> Start says "Shows on your next mission run" and the next run shows every tip
  again; `/crimsonhelp run` does the same with a message. `Config.Training.autoStart.run = false`: no tips. (TR2)
- [ ] HUD on the left (My options -> HUD side), small and large HUD sizes, 720p: the tip stays in the HUD column and
  the column still fits the screen. (TR2)

## Every workflow end to end

- [ ] Admin only: an officer who sends a setting change gets refused; the admin turns on Volunteers, Volunteers → modes (Investigation: players when available), the criminal tablet (Features), access Granted and Pay volunteer suspects in Settings, each at once, no restart. (G7)
- [ ] Permissions → Extra grants → Criminal tablet for Ballas from grade 1: a Ballas grade 1 member opens `/crimtab`; a civilian outside the gang is refused; an officer on duty is refused. (G7)
- [ ] The Ballas member gets on the list from Home; a unit accepts Investigation with Real suspect OK: Jobs shows the job with its Reward line "$1,500 if you get away, $500 if you are caught" and no position. Accept, travel, the unit reaches him (Active: giving up is no longer free), he runs and the unit gives the mission up: he is paid $1,500 cash once, History shows "got away" and no strike. (G7)
- [ ] Live control → anti-farm → Clear cooldowns for both officers, and Settings → Real suspects: Job hop minutes and Suspect cooldown 0: the same unit and volunteer play again at once. He accepts, the unit waits at the start, after 60 s he presses Give up: one strike in History, Active empty, nothing paid. (G7)
- [ ] Settings: Item rewards On with a Patrol pool, Mission controls On, Give points On, Give points money On. An officer plays Beat Patrol to the end: the result screen shows $250 and the item; the bank and the inventory get them once. (H7)
- [ ] A SAST trooper and an FIB agent in one unit play Gang Shootout: each row is Reinforced with two departments, each is paid $920 and gets the item. (H7)
- [ ] A sergeant creates a Patrol call on Dispatch; a trooper claims it, a second trooper is refused; the run pays as a normal Patrol. (H7)
- [ ] The sergeant clears a trooper's Beat Patrol cooldown (he can take it again), sets the hourly cap inside the admin's bounds (Department -> Controls shows it), gives 20 points ($100 and the item once; an FIB sergeant and his own character are refused) and commends him. (H7)
- [ ] A flagged run keeps its cash and items until a supervisor of its department approves it; a voided run keeps them until the officer's dispute is approved. (H7)
- [ ] Settings: Live crimes On, Live-case cash On, Item rewards On, Pay talk-downs On with water x1, Field training On, Tasks `{ "tactical": 1 }` (saved: leaving the other types out is allowed now), Trainer bonus 10, Pay field training sign-offs and Pay finished field training On. (H8)
- [ ] A crew of two does a Warehouse Burglary: the LIVE card shows "2 suspects"; a unit claims it, secures the scene; a third officer reaching the scene gets "Join the live case?" and joins. Cuff A 30 s (detained), book him at Mission Row for 10 months (booked). The third officer gets "close enough to talk down", Talk them down, B says Yes, cuff him 30 s: Peaceful arrest, and that officer gets $300 and the water once. End case: three rows, each paid the Investigation pay once. Admin UI → Real suspects lists the case; its timeline has joined, talk down, surrendered, peaceful arrest and end case. (H8)
- [ ] Claim a second crime, get a suspect to surrender, then `restart Crimson-Police` before anyone cuffs him: no officer is on a case, no row, no pay, no cooldown, no LIVE call; Settings changes are kept; the first case is still on Real suspects with its timeline; `/surrender` says he is not wanted. Form the unit again: the next crime posts a LIVE call and pays as usual. (H8)
- [ ] Field training: an officer cannot pair; a sergeant pairs a cadet with a trainer. Start Gang Shootout as their unit and restart: the run did not count and the pairing is kept. Play it again to the end: the trainer gets the "ready" toast. Restart again: Profile → Field training still shows the task ready. Another supervisor cannot sign off; the trainer can: the cadet gets the Field Training badge, the trainer $250 and 10 points, the cadet $1000. A further restart pays nothing twice. (H8)
- [ ] A supervisor creates a mission call (or the tablet posts one), an officer claims it and drives to the start,
  then `restart Crimson-Police`: after the restart Supervisor UI → Mission calls (today) and the dispatch history show
  the open call as Lapsed and the claimed one as Ended by a restart, never Open or Claimed; new calls post as usual.
  (WF1)
- [ ] Play through docs/dev/WORKFLOWS.md once on a test server with every switch on, with one `restart Crimson-Police`
  and one player quitting and coming back in the middle; each row's result matches. (WF1)
- [ ] On a test server without sc-dispatch, sc-ambulance, Renewed-Banking and sc-police (or with Admin UI -> Settings
  -> Other scripts all set to none): a patrol, a unit mission, a mission call and a supervisor award each run to the
  same result and pay as with them; the console names each script that is off once. Then click through every screen
  of the Officer, Supervisor and Admin UI and the criminal tablet: none shows an error card. (WF4)
- [ ] Review Queue: Approve or Void a flagged run: the row leaves the list at once, with no reload flicker; the same
  for answering a dispute. (Pure speed-up: the reply carries the new queue.)
- [ ] Dispatch: Decline a pushed mission: the card leaves at once. Business Check: log a door on Active Mission: the
  next door's buttons show as soon as the server takes the log (no fixed wait).
- [ ] Give 10 points with a reason, open Give points for another officer: 10 and the reason are filled in; the same
  for Mission ban (hours, reason) and Clear cooldown (reason). Restart Crimson-Police: the dialogs open empty.
- [ ] Errors read with a next step: claim a call another unit just took ("Pick another call on Dispatch"), invite
  into a full unit ("Its leader can remove a member to make room"), submit a supervisor dialog with no reason.
- [ ] Admin UI -> System -> Backups: Backup now, then Delete an older backup: the list changes at once (one request,
  the reply carries the list). Restore one after typing RESTORE: the list shows the automatic backup at once.
- [ ] Admin UI -> System -> Storage: Copy all data to the other storage, then at once Copy again or Switch storage:
  the panel shows the new state at once and never says "too many requests" (the reply carries the view).
- [ ] Supervisor UI: post, page (with a pushed mission) and withdraw a mission call; Recall and "+ minutes" on Live
  Missions; Give points, Mission ban, a commendation and Clear cooldown from Department Report: each list changes at
  once with no reload flicker (the reply carries the view). Admin UI -> Officers: Void or Restore a run in the run
  dialog: the run, the run list and the officer's totals change at once; Settings -> Reset all: the screen shows the
  config.lua values at once. (FX1)
- [ ] Two SAST supervisors open the Review Queue; one approves a flagged run: it leaves the other's list at once. A
  FIB supervisor's list does not change. (FX1)
- [ ] Quit and rejoin: a suspect of a live crime quits and comes back within two minutes: he is still on the case card
  and can be cuffed; a volunteer quits and comes back while engaged: his criminal tablet shows the case again, no
  strike; a rookie quits mid-run: the run goes on for his trainer and does not count; a trainer quits and comes back
  before the sign-off: Sign off still works. (FX1)
- [ ] Errors read with a next step: delete the newest backup ("Delete an older backup instead."), void a run that is
  already voided ("Use Restore on it to undo the void."), import a file that is not a settings export.
- [ ] `Config.Rewards.enabled = true`: a flagged run with held item rewards is voided by Void runs, then the batch is
  restored: the items stay held while the run is in the Review Queue and come only once a supervisor approves it. (Z7)
- [ ] Real suspects with `onLeave = 'escaped'`: an engaged volunteer in a flee-and-arrest logs out and the run fails at
  once: his criminal tablet History shows "Left the case", he gets a strike and no feature pay. Shipped `'void'`: a
  volunteer who disconnects just before the run ends gets the same strike. (Z7)
- [ ] Two volunteers listed: the first says yes just as his window runs out: he gets the case and the second
  volunteer is not asked. The rs_linked_accounts flag detail names what is shared (for example "shared ip"). (Z7)
- [ ] Admin UI -> System -> Backups with a folder that cannot be written (or a full disk): Backup now fails with the
  write error and leaves no new files in saves/_backups. (Z7)
- [ ] `allowManualCash = true`: a manual cash payment sent during a maintenance lock shows Pending, and the officer is
  paid when the lock ends or at his next login. (Z7)
- [ ] `Config.Cash.dailyCap > 0`, society mode: Pay the rest on a capped suspect reward paid as a money item gives the
  money item and takes nothing from a department account. (Z7)
- [ ] An admin on duty as FIB opens the SAST Department Report while only SAST has Mission ban on: the button shows
  with SAST's hour range, and the ban works. (Z7)
- [ ] Files mode, Settings -> Database -> jsonCacheEntries 0: resmon memory drops after the next badge check and the
  lookups still answer the same. (Z7)
- [ ] Files mode with paid rows: run `/CrimsonPoliceAdmin storage copy database-to-files force` in the console: the
  maintenance lock is on during the copy, paid rows stay paid (no second payment at the next login), and the console
  and Admin UI ask for a restart. (Z8)
- [ ] Real suspects -> Exclude on a player, then he commits a Crimson-Contracts crime: he is not a suspect of the
  LIVE call (the live crime audit says "excluded"). (Z8)
- [ ] `Config.FeatureRewards.suspect.enabled = true`: a volunteer case flagged rs_pair_repeat pays the volunteer
  nothing. (Z8)
- [ ] `Config.RealPlayers.liveCrime.enabled = true`: a LIVE claim whose crime ends before the case opens shows Abandoned
  (cancelled) in History, not Failed, and adds nothing to the leaderboard failed column. (Z8)
- [ ] Parking Patrol with a returning driver who argues: run him over with an NPC car (or let traffic kill him): the
  objective completes instead of waiting for the time limit. (Z8)
- [ ] Flee and arrest, field contact, hostile waves, protect and rescue: an officer who left the run kills a cuffed or
  unarmed NPC: the run does not fail for the officers still on it. (Z8)
- [ ] Approve a flagged run while a maintenance lock holds payments: the row stays Held, then the officer's next
  login (or Admin UI -> Payments -> Pay now on that row) pays it. (Z8)
- [ ] `Config.RealPlayers.liveCrime.enabled = true`, `readyCheck = true`: a unit member responding to the crime's own 911 call
  in sc-dispatch does not cancel the ready check, and the unit can claim the call. (Z8)
- [ ] Cross-Department join window: mission-ban a joined officer (or turn his department's crossDept join off), then
  Start now: he is removed at the start with the toast, and is not on the run. (Z8)
- [ ] Admin UI -> Audit -> Save to server with saves/exports read-only: the save fails with the write error and no
  success toast. (Z8)
- [ ] Admin UI -> Live -> End run on a normal run: the officers' toast says the run was cancelled, not the
  Cross-Department Mission. (Z8B)
- [ ] A unit of two with the ready check: mission-ban the second member before he answers, then Ready: the start is
  refused with the member-banned toast and the unit is free again. (Z8B)
- [ ] Approve a flagged run whose pay shows Pending: it pays at once, not at the officer's next login. (Z8B)
- [ ] Item rewards: approve a held run while `Config.Rewards.enabled = false`, turn rewards on again: the items come
  at the next login. (Z8B)
- [ ] Bulk void a paid run whose items were forfeited after the dispute window, then Undo: the items come back.
  Flag a run by hand (Admin UI): its pending items show Held. (Z8B)
- [ ] `Config.FeatureRewards.surrender.enabled = true`: a talk-down is paid when the case ends, never on an abandoned
  or cancelled case or for a flagged officer. (Z8B)
- [ ] Admin UI -> System -> Storage copy while a run is going: the toast names the run count, no `{count}`. (Z8B)
- [ ] Process the scene: destroy the coroner van once it is called: Release to coroner moves to the scene marker.
  (Z8B)
- [ ] An admin who is also an FIB officer approves a SAST flagged run:
  a SAST supervisor with the Review Queue open sees it go. A non-supervisor granted reviewFlagged sees the Review
  badge count. (Z8B)
- [ ] Push a mission twice at once (double click) with one push left today: only one goes out. A SAST supervisor
  cannot withdraw an FIB lane call. Department -> Controls counts a started happy hour. (Z8B)
- [ ] `Config.RealPlayers.liveCrime.enabled = true`: a crew of two where one suspect already scored maxCatchesPerSuspectDay
  today: catching him adds no detain line, catching the other one does. (Z8B)
- [ ] Two runs ask for a volunteer at the same moment: he gets one pop-up only. (Z8B)
- [ ] Change `Config.Custody.reach.plateFromVehicle`, `Config.Recognition.commendations.sameKindCooldownDays` or
  `Config.Profile.reports.reasonMax`: the matching refusal names the new value. (Z8B)
- [ ] Switch the storage in Admin UI, restart, then `storage copy database-to-files force` (or the reverse): the next
  start is not locked as 'left behind'. (Z9)
- [ ] Right after a storage switch (before the restart), run a storage copy: it is refused with the maintenance
  toast and the restart prompt stays. (Z9)
- [ ] `Config.RealPlayers.liveCrime.enabled = true`: the same officer and real suspect meet a third time with a fast catch: the
  officer's row shows in the Review Queue as rs_pair_repeat, unpaid cash shows Held. (Z9)
- [ ] Give a feature reward or a manual cash payment, then stop the resource while it pays (a payment lock wait):
  after the restart the row shows Pending and the login pays it. (Z9)
- [ ] Mission controls: switch No-repeat off: the toggle stays Off and an officer may draw his last mission again.
  (Z9)
- [ ] Extra grant forceRecall to an officer: he sees Live Missions and can recall an officer of his department. (Z9)
- [ ] Go down on a live or volunteer case: the toast says "no type cooldown" and the mission shows its cooldown on
  the board. Officers / Review Queue show "Vehicle removed by someone outside the run" for that end. (Z9)
- [ ] `Config.Cash.source = 'society'`: Pay again or Pay the rest where Qbox refuses and the refund fails: the toast
  says the department was charged and it stays for a manual check. (Z9)
- [ ] With `Config.Retention.runArchiveMonths` set, an old completed row still owed ('none' with cash) stays in
  cp_mission_runs after the daily reset and is paid at the login. (Z9)
- [ ] Start a backup restore or a storage switch while an officer accepts a mission at the same moment: one of them
  is refused, never both going. (Z9)
- [ ] Live case: once the scene is secured the HUD shows "Detain and book the suspects" without the 60/60 bar. (Z9)
- [ ] Drug stash search with Seize: find every stash, cancel one Seize bar: that stash keeps its orange point and
  GPS line, the checklist stays open until it is seized. (Z9)
- [ ] A SAST supervisor decides a SAST + FIB run's row: an FIB
  supervisor with the Review Queue open sees it go at once. (Z9)
- [ ] An officer with a builderEdit grant runs a draft test: the audit log shows role supervisor, not admin. (Z9)
- [ ] An admin's Review badge counts the admin-only flag kinds his Review Queue lists. (Z9)
- [ ] A department readyCheck Mission control of 40 s: other officers' cards count down 40 s while a call is
  claiming. (Z9)
- [ ] A second supervisor starting a happy hour the same day is refused (happyHour.perDay is server-wide, as the
  docs now say). `/CrimsonPoliceAdmin missioncall` with no type prints the command name, no `{cmd}`. (Z9)
- [ ] Admin UI -> Audit -> Save to server while staff act: the file holds the rows there when it began, no
  duplicate. (Z9)
- [ ] A two-officer run goes In progress while the partner still drives: he follows the action and is not removed
  as idle at 180 s; he has followActionSeconds (300 s) to arrive. (Z10)
- [ ] `Config.RealPlayers.volunteer.enabled = true`: an officer and a volunteer who share a PC or connection end a run: the
  volunteer is not paid (rs_linked_accounts), also when the run ends while the 2 s anticheat pass runs. (Z10)
- [ ] With allowCapTopUp or allowPayAgain on, flag a capped or paying row for review: Pay the rest and Pay again
  refuse with "flagged for review"; Payments shows no Repay, Retry or Pay the rest on a flagged row. (Z10)
- [ ] Void a held row in a batch, press Cancel payment on it, then Undo the batch: the row stays Forfeited. (Z10)
- [ ] `Config.RealPlayers.routeEnds = 'start'`: cuff and detain the suspect before the unit reaches the start
  circle: once In progress the detain (and booking) lines are on the run. (Z10)
- [ ] A hidden device search with together on, done by two officers: the devices appear, and the next skill check
  has them as targets. Also when the partner leaves while a spot is held. (Z10)
- [ ] Open the Officer UI at a mission desk, close it, walk away and type /CrimsonPoliceAdmin: the Admin UI stays
  open. With requireItem on, switch from the Admin UI to the Officer UI and drop the item: the tablet closes. (Z10)
- [ ] A supervisor with builderEdit and no builderTeleport grant tests a draft: Teleport is refused; an admin's
  test Teleport writes a testControl audit row. (Z10)
- [ ] Restore a backup while officers log in: the restore works. (Z10)
- [ ] `Config.RealPlayers.volunteer.enabled = true`: a Warrant Service with a volunteer runner, two officers chase him far from
  the door: nobody is flagged 'presence'. (Z10)
- [ ] An officer with an extra missionControls grant has Mission controls open while a supervisor changes one: his
  screen updates. Two supervisors press Start happy hour together: only one starts, the other gets "Someone is
  changing this Mission control". (Z10)
- [ ] Open Dispatch on several tablets while calls change and tablets open and close: every open screen keeps
  updating. (Z10)
- [ ] Load audit export part 1, do an admin action, then load part 2: no row of part 1 repeats. (Z10)
- [ ] In a test run, Restart objective on Process the scene after bagging a body: the old coroner van and the bag
  props go, and no all_taken_alive bonus is given. (Z10)
- [ ] The clawback dialog names "bank or cash"; real suspects Block / Exclude / Suspend with 0 days say "above 0";
  an old case's text says nothing about a restart. (Z10)
- [ ] During a maintenance lock, `/CrimsonPoliceAdmin award <cid> 50 reason` is refused with the maintenance
  text. (Z10)
- [ ] Scroll a long board far down, filter it to a few rows, clear the filter:
  the rows show at once. (Z10)
- [ ] The extra parts of Map markers ship off: with `Config.Markers.extraParts = false` a run shows only the objective
  blips, the prisoner van and the tow truck. Turn on Admin UI -> Map markers -> Turn on and the parts `coronerVan`,
  `coronerDrop`, `evidence`, `parkedCar` and `partner`; on a Process the scene run the coroner van, where it parks and
  the body bags show on the minimap and the big map, the parked cars near the scene, your partner in blue (not
  yourself). (BL1, MG1)
- [ ] Add a rule `partner = { roles = 'leader' }`: only the run's leader sees partners, within a few seconds, no
  restart. With Radio Silence the parked cars and partners go; the van and the bags stay. (BL1)
- [ ] A Manhunt with `hidingSpot` on: no hiding spot shows until a fugitive runs; then his spot shows. A live case
  with `reportedPoint` and `hospitalDrop` on: the suspect's own position never shows, only the reported points, and
  the hospital while he is down. (BL1)
- [ ] End the run, leave a run, log out: every extra blip goes. resmon on a run with every part on stays under
  0.05 ms. (BL1)
- [ ] Admin UI -> Map markers is listed under Missions. On top: the
  objective's settings and the look of each kind of objective blip; change the Mission start colour: the next start
  pin has it. Turn on the extra parts: the card turns green. Switch on Coroner van, pick the picture Van and the
  colour Purple: on the next Process the scene run the van shows with that look, no restart. Settings -> Features
  has one Map markers row (no Extra mission blips row). (BL2, MG1)
- [ ] Map markers -> Partner -> Change who sees it: tick SAST, pick The run's leader only, Save: the row shows
  the two limits, Settings -> History has the change, and only the run's leader sees partners if he is SAST. Remove the
  rules: everyone on the run sees them again. (BL2, MG1)
- [ ] Map markers, a part with `roles = 'leader'`: the officer who started the run leaves it (or drops): the next
  officer (the new host) sees the part within a few seconds. (Z11)
- [ ] Map markers with `suspectVehicle` on, a Traffic Enforcement run: no blip on the violator while it drives
  toward the observe point; it shows once the car has passed you, as the objective blip does. (Z11)
- [ ] Map markers during a run: change a part's colour or label: the coroner drop-off, hospital or other still blips
  change within a second, no new list needed. (Z11)
- [ ] Map markers, a live case with `hospitalDrop` on: a suspect goes down, then disconnects: the hospital blip
  goes. (Z11)
- [ ] Map markers -> Change who sees it: tick a choice, then save another setting (or another admin saves one):
  the ticks stay until you save or cancel. The On count leaves out Prisoner van and Tow truck (they have their own
  switch, and their rows say so). (Z11, MG1)
- [ ] One blip system: request a prisoner van and a tow truck with the extra parts on and every part on: each shows
  once (one blip, blue, "Prisoner transport" / "Tow truck"), never a second blip. Switch Prisoner van off on Map
  markers: its blip goes within 2 s; on again: back. Give it a new colour or label: the next van has it. A rule
  `prisonerVan = { grade = 3 }`: an officer below grade 3 gets no van blip on the next van. (MG1)
- [ ] One way to do each thing (BK1): Settings has no groupSidebar, groupByPlay, plainLayout, landing, settingsView,
  homeForms, markersScreen, needsAttention, oneRequest, windowRows, foldAdvanced, quickWizard, supervisorByTask,
  supervisorRemember or supervisorReviewLive; a value saved for one of them before the update gives no console line
  and no Problems line.
- [ ] Back up now, then restart Crimson-Police while it writes (big store): after the start, saves/_backups holds no
  `.t.*.json` or `.f*.bin` without a matching `.manifest.json`. (Z11)
- [ ] A restore that fails part way, then the fix restore of its automatic backup works: the reply and the audit
  line name the first automatic backup; the second one is gone and the first stays protected. (Z11)
- [ ] Admin test run of a pursuit that hands off to a stop: Restart objective on the stop: the car and occupants stay
  and can be worked again; the stop does not complete with 0/0. (Z11)
- [ ] Live crimes on, an officer at his hourly cap (Mission controls hourlyCap 1, one run done): a LIVE claim is
  refused, and the backup join pop-up answers "You reached the hourly limit..." too; he is not added. (Z12)
- [ ] FeatureRewards.supAward on: award points to an offline officer, then void that award row (Admin UI -> Runs):
  at his login no award money is paid; restoring the row (a dispute) pays it once. A live run row voided after a
  Talk them down does the same for its surrender reward. (Z12)
- [ ] Stolen Vehicle Takedown, wreck the suspect car: the stop completes at once with nothing to work, and the run
  is not held for review as too fast. A pursuit skipped by team (Traffic Enforcement, one officer) is not either. (Z12)
- [ ] Admin bulk void or a Settings revert with a 200 character accented reason (e.g. "é" repeated): the job starts
  and Settings -> History has the row. (Z12)
- [ ] Cash.source = 'society' with Integrations.banking = 'none': Admin UI -> Problems shows no "account does not
  exist ... unfunded" line, and no low balance toast. (Z12)
- [ ] Add a department in game, change one of its Mission controls, delete it, add it again with the same key:
  its Mission controls start from config.lua. (Z12)
- [ ] Manhunt: cuff the fugitive: the officer's service record and the arrests leaderboard count one arrest. (Z12)
- [ ] Unit with a 40 s ready check (readyCheck control): the last member answers after 35 s; the run starts and
  the leader cannot kick or disband during it. (Z12)
- [ ] Cross-Department Mission with readyCheck on and no unit on the server: a team member disconnects or goes off
  duty during the check: it is cancelled at once with the toast (not after the timeout). (Z12)
- [ ] unitSize SAST 2, LSPD 4 (or FIB): a full SAST unit of 2 is not listed on an FIB leader's invite list; a
  SAST leader sees FIB officers in a unit of 3. (Z12)
- [ ] Markers.rules.prisonerVan = { roles = 'leader' }: request a van, the leader leaves the run: the new leader
  gets the van blip within a few seconds, the old one loses it. (Z12)
- [ ] Real suspects timeline of a live case: the repeated pairing line names the officer, and the scene steps read
  "Officers reached the scene", "Officers secured the scene", "<officer> ended the case" (no bare codes). (Z12)
- [ ] Review Queue: approve or void a flagged run: the Department sidebar badge and the Waiting for review tile
  drop within about a second, for you and for another supervisor with the queue open. (Z12)
- [ ] Active Mission with a counter that moves twice within 2 s (two quick catches): the tablet shows the new value
  within about 2 s, without waiting for the 15 s refresh. (Z12)
- [ ] Mission Builder mission with two field_contact objectives (bestPoints 20 and 5): two Best decisions in the
  first and one in the second give 45 points for correct_disposition. (Z12)
- [ ] One restrictions list (FM5): suspend an officer for 2 days (Officers), give another a mission ban (supervisor
  officer dialog, Mission controls on): Admin UI -> People -> Restrictions lists both with who set them, until when
  and why. Extend the ban by 2 hours: Until moves on 2 h and the officer is told; Lift the suspension with a reason:
  he can open the tablet again and the Activity log has the unsuspend. With live crimes on, a pair block set under
  Real suspects -> Pairs and blocks shows in Restrictions and lifts there. (FM5)
- [ ] One jobs screen (FM9): Admin UI -> System -> Jobs lists the daily backup (Off), the clean-up, the mission call
  history, the real players jobs, the low balance warnings, the planned season end, the weekly bounty and recognition,
  the monthly top 3 and both forfeitures, each with its next run and settings. Clean-up -> Run now with a reason: its
  last line shows your id and the counts, and the Activity log has Job run now; a second press within 10 minutes is
  refused. Weekly recognition has no Run now. After the next daily reset every daily job shows a last run. (FM9)
- [ ] Other scripts (SALE1): with sc-dispatch, sc-ambulance, Renewed-Banking and sc-police running and
  `Config.Integrations` as shipped, Config health shows "Dispatch script: sc-dispatch" and the other three, and
  everything works as before (a real call releases a run, EMS is asked for a downed officer, a payout has its bank
  line, a live-crime cuff and jail count). Set `Integrations.ambulance` to `none` in Settings: a downed participant is
  picked up and revived by Crimson-Police even with EMS on duty. Set `Integrations.police` to `none` with live crimes
  on: the console has one line, Config health warns, and Settings -> Features says why live crimes are off. Put both
  back to `auto`. On a test server with ps-dispatch, qbx_ambulancejob and qbx_policejob instead: Responding on a
  ps-dispatch call releases the officer from his run, EMS counts the `ems` job, and a pick-up revives. (SALE1)
- [ ] Other scripts, part 2 (SALE2): in config.lua set `Config.Integrations.dispatch = 'cd_dispatch'` and restart:
  Config health says Crimson-Police has no adapter for it (not "start sc-dispatch"). Name `ps-dispatch` while it is
  not running: Config health warns that it is not started. Put it back to `'auto'`. With Settings -> Cash source
  `society` and `Integrations.banking = 'none'`, a department's society account can be changed (no "account does not
  exist"). On the ps-dispatch test server: Responding on one call, then on another, leaves the officer on the second
  only, and his run stays a free abandon. (SALE2)
- [ ] First-start setup (SALE3): as shipped, Admin UI -> Home opens on its dashboard (no setup). In Settings set
  `AdminUi.setupScreen` on: Home shows First-start setup above the dashboard. Step 1 lists your departments with
  their Qbox jobs and supervisor grade, and the qbx_core police jobs no department lists; step 2 the desks; step 3
  where data is saved; step 4 the four scripts found (sc-dispatch, sc-ambulance, Renewed-Banking, sc-police here);
  step 5 the presets. Change nothing and press Finish (0 changes): the setup goes away and the Activity log has
  "First-start setup finished"; the departments, desks and scripts are as before. Set `AdminUi.setupDone` off,
  then Skip setup (two clicks): it goes away again. Set `AdminUi.setupScreen` back off. (SALE3)
- [ ] Generic config (SALE3), on a stock Qbox test server only: copy `config/examples/generic.lua` over
  `config/config.lua` and restart: the start-up check has no red line, the departments LSPD, BCSO and SASP match
  the jobs `police`, `bcso` and `sasp`, and `/CrimsonPoliceAdmin` opens on the First-start setup. (SALE3)
- [ ] Sale readiness (FIN10): Admin UI -> System -> Integrations: each script row that serves a job says which one
  (sc-dispatch "Dispatch script" and so on), and *Who serves each job* lists the four jobs. Set
  `Integrations.ambulance` to 'none' in Settings: its line gives the reason. Put it back to 'auto'. With
  `AdminUi.setupScreen` on and a Qbox police job no department lists, tick it in step 1, pick "The same as" a
  department and a logo link: after Finish the new department has those colours and that logo. (FIN10)
- [ ] Finish (FIN1): Supervisor UI -> Department -> Officers -> an officer -> Give points: *Your controls used today*
  goes up at once (no 30 s wait). A rookie whose training is done shows his finished training and Pair trainer in
  the panel; pairing him again works as on the Training tab. Admin UI -> Money, Review and Supervisor Department
  switch tabs as before and a Home tile or a search result still opens the right tab. In Settings set
  `AdminUi.homeShortcutsByUse` on, use Change pay three times from Home, reopen Home: Change pay is first; set it
  back off: your order again. Screens look as before (the spacing now comes from the shared scale). Paged lists
  read "Page n of m". (FIN1)
- [ ] Finish (FIN2, the shared helper library): with two admins, open the same officer and press Forgive streak days
  (or Reset first run) at the same moment: one goes through, the other says busy, and a second try says once a day.
  Stop Renewed-Banking and pay a society-funded run twice within a minute: the console shows one "Renewed-Banking
  is not started" line a minute, not one per call (a failing export prints one `[crimson-police:ext]` line a
  minute the same way). Toasts still arrive
  for commendations, level-ups, goals, mission bans and field training; the Mission Builder, custody and the testing
  panel still refresh on the tablet; desks and the cuff and contact options still work through ox_target. (FIN2)
- [ ] Finish (FIN4): as an SAST supervisor ban an officer (Department -> Officers), open Department -> Restrictions:
  the ban shows with you as setter and Lift; a second SAST supervisor sees it without Lift; a suspended SAST officer
  shows read only. Lift it there with a reason (the officer can take missions again; the officer dialog lift still
  works). With `Config.MissionControls.restrictionsTab = false` the tab is gone. Real suspects -> Pairs and blocks
  shows Open Restrictions instead of its own running rows.
- [ ] Finish (FIN4): Admin UI -> Review -> Queue: bulk void two runs of an officer (Officers -> Corrections), the
  batch shows in the queue under Corrections; Undo it there with a reason (the rows come back, Corrections shows it
  undone). Void a flagged run in the queue: the Undo line restores it (Restore run in the Activity log). History on a
  flagged run lists its row, the flag, any decision and dispute, oldest first; the same list is in Officers -> an
  officer -> Runs -> the run.
- [ ] Finish (FIN11): quit the game half way through a Suspicious Activity, a Traffic Enforcement and a Parking Patrol,
  and as the partner of a Drug Lab Raid: each time the row is Failed with no cash, the mission is on its cooldown and
  you are on no run when you rejoin (the raid goes on for the leader). Go down on a patrol and quit before the pick-up:
  one Downed row. In Settings -> Other scripts set one kind at a time to none (dispatch, ambulance, banking, police):
  a patrol and a mission call still end and pay the same. Turn `Config.Blocks.pursuit.wreckHandoff` on and wreck a
  Traffic Enforcement violator with the driver alive: the stop lists him (no car) and you can work him. Turn
  `Config.FeatureRewards.suspect.voidWithRun` on: void every officer row of a paid volunteer case and the suspect's pay
  row is voided; restore one and it comes back.
- [ ] Deep sweep (Z13): give an offline officer a supervisor award, void the award's row, cancel its payment
  (Admin UI -> Money), restore the award row: the payment stays cancelled and his login pays nothing. (Z13)
- [ ] Deep sweep (Z13): stop MariaDB for a moment while a backup runs (System -> Backups -> Back up now): the backup
  is refused with "A table could not be read", no half backup is listed, and a restore takes no pre-restore backup
  with a table left out. (Z13)
- [ ] Deep sweep (Z13): a volunteer says yes to a run and cancels within the grace time: the NPC plays the suspect and
  the officers' result pays the mission cash and counts for goals and the challenge again. (Z13)
- [ ] Deep sweep (Z13): First-start setup: untick every department and press Finish: refused (one must stay on). Move
  a job from one department card to another in one Finish: accepted. Turn off a department whose job is not a Qbox
  job (Admin UI -> Departments): accepted. (Z13)
- [ ] Deep sweep (Z13): a builder mission with an interact_points step whose together.count is above its points is
  refused on save; a saved one completes with as many officers as points. (Z13)
- [ ] Deep sweep (Z13): a custom mission whose first objective is a pursuit with complete = all_or_timeout_any and a
  second objective: detain one racer and let the clock run out: the run is Failed (time limit), not Completed. (Z13)
- [ ] Deep sweep (Z13): with requireTrainerFor = { 'tactical' }, a rookie joins a tactical Cross-Department Mission
  without his trainer: he is dropped at the start with the "removed at start" toast. (Z13)
- [ ] Deep sweep (Z13): with Tactical switched off for SAST (Mission control), an SAST officer cannot join a tactical
  live case as backup either (Off for your department). (Z13)
- [ ] Deep sweep (Z13): claim a LIVE call: Active Mission shows $0 expected cash with liveCrime.cash off, and no base
  points with linesOnly on. (Z13)
- [ ] Deep sweep (Z13): Parking Patrol with a returning driver who argues: the checklist and HUD stay at N of N+1 until
  an officer explains the citation. (Z13)
- [ ] Deep sweep (Z13): with adjustDailyLimit = 100, award 80 with /CrimsonPoliceAdmin award in game, then 30 more:
  the second is refused (over your daily limit); the console has no limit. Two Give or take points at once: one says
  busy. (Z13)
- [ ] Deep sweep (Z13): after an in-game Switch storage, run storage copy: the next step names System -> Storage ->
  Switch storage (or storagemode reset), not config.lua alone. Settings -> Database says the same. (Z13)
- [ ] Deep sweep (Z13): test a Traffic Enforcement, stop the car, press Restart: the next contact stop takes only the
  new car. Test a Parking Patrol, let the returning driver take his ticket and Restart within 30 s: the new parked
  cars stay. (Z13)
- [ ] Officer workflows (WF5A): open the Officer UI with /CrimsonPolice, the key and at the Mission Row desk (away from
  it, the desk is refused); set Settings -> Tablet item and use it; require the item: without it the command and Accept
  are refused, a desk still opens. Accept one mission of each built-in type from the Mission Board and play it to the
  result card: the points and cash on the card match Profile -> Runs, the bank and the item. Fill your pockets and
  finish a run: the item waits in the Rewards locker; make room and claim it once. In a unit, quit while the ready check
  asks you: nobody gets a run or a cooldown and the leader can accept again. Decline a pushed mission on Dispatch: it
  leaves the list at once. Pick call pop-ups for favourites only: another type shows on Dispatch with no pop-up. Turn
  Hide my name on: another officer sees your callsign on the leaderboard. (WF5A)
- [ ] Supervisor workflows (WF5B): open the Supervisor UI as a supervisor (an officer and a cadet are refused); Today
  counts your department's officers on duty and its runs. From an officer's panel commend, then revoke with a reason;
  with the Mission controls on give 50 points (51 refused, 100 a day), bar an officer for 2 hours (another supervisor
  cannot lift it), clear one cooldown. Switch the no-repeat rule off in Mission controls: the row shows it changed by
  you with Reset. Start a 10 minute happy hour: an officer's cooldowns are lifted, yours are not. With the department's
  second Void on, void a flagged run, restart the resource, and have the other supervisor void it: it is voided (the
  first Void was kept). As a unit leader accept a type that has no mission for your unit size: after Ready you get a
  toast saying no mission was left. (WF5B)
- [ ] Admin workflows (WF5C): open the Admin UI as an admin (a supervisor is refused) and check Home's on-duty count,
  queues and the five shortcuts; search an officer by name. Suspend an officer for a day and lift it. Add a department
  for a Qbox job, rename it, turn it off (its officers lose the tablet) and on again. Add a desk where you stand, limit
  it to one department, remove it. Switch Beat Patrol off and on; make a mission in the Mission Builder, test it,
  publish it; edit EVOC and Reset to original. In Settings, Markers -> Rules, save a rule with a typo (a part, a
  department or a mission type that does not exist): it is refused with a message naming what to fix. Set Patrol pay
  to $400 and play one. With Pay by hand on (ENABLE), type a citizen ID nobody has: the message says no officer has
  that ID. Make a backup, restore it (RESTORE): every change waits until you restart the resource. (WF5C)
- [ ] Real players (WF5D): turn on live crimes, volunteers and the criminal tablet in Settings. Report a crime with
  Crimson-Contracts: a unit claims the LIVE card, a third officer gets the join pop-up at the scene, one suspect is
  booked and one talked down; End case pays each officer. Volunteer on the criminal tablet, get a strike (Give up after
  the free minute) and restart the resource: History still shows the strike. Set the police script to none in Settings
  -> Integrations: the criminal tablet says volunteer suspects are off, Get on the list is refused, and
  `exports['Crimson-Police']:GetAvailablePolice()` answers nil; set it back to sc-police. (WF5D)
- [ ] Deep sweep (Z14): force a storage copy into the other store and stop MariaDB part way: the other store gets its
  money state back (Admin UI -> Money shows paid rows still paid after the retry copy). (Z14)
- [ ] Deep sweep (Z14): force a copy into the store in use and make it fail part way, restart: the maintenance lock is
  back at the start (console line names the copy); run the copy again with force: it runs, then asks for a restart,
  and the next start has no lock. (Z14)
- [ ] Deep sweep (Z14): with Config.RealPlayers.liveCrime.linesOnly = false, go down in a live case: your row shows
  the lines you earned only (no base points, no fast_finish) and no mission cash; a teammate who finishes scores more.
  (Z14)
- [ ] Deep sweep (Z14): award points to an officer, move his record to another citizen ID in Corrections, void the
  award row: its money row is voided too, and restoring the award brings it back. (Z14)
- [ ] Deep sweep (Z14): report a live crime, put one crew member on SAST duty before a unit claims it: the case opens
  with him void and the rs_went_on_duty note; officers cannot score him. (Z14)
- [ ] Deep sweep (Z14): while you are a suspect of an open live case, go on duty and try to claim another LIVE call
  or join one as backup: refused (recent suspect); a volunteer case skips your unit too. (Z14)
- [ ] Deep sweep (Z14): fill a Cross-Department Mission with a waitlist, send one joiner into the arena and press
  Start: the first waitlisted officer takes his place and is told. (Z14)
- [ ] Deep sweep (Z14): start a Cross-Department ready check and answer Not ready on one member: the Ready banner
  closes for everyone. During a team check, invite one member to another unit: his banner stays. (Z14)
- [ ] Deep sweep (Z14): set Training.command to tablethelp in Settings and restart: /tablethelp opens the tours,
  /crimsonhelp does not; a name such as 1help is refused. (Z14)
- [ ] Deep sweep (Z14): two admins switch two missions off at the same moment (or add two desks at once): both
  changes stay. (Z14)
- [ ] Deep sweep (Z14): a supervisor changes a Mission control, another resets it within 5 minutes: refused with the
  change wait. (Z14)
- [ ] Deep sweep (Z14): start a field_contact objective from far away: the HUD says Waiting for the contacts, then
  Contacts decided: 0 of N once they appear. (Z14)
- [ ] Deep sweep (Z14): change two options quickly on the Officer UI Options screen and close it: reopen, both are
  saved. (Z14)
- [ ] Deep sweep (Z14): flag a pending payment row in Admin UI -> Money: Pay now is not offered for it. (Z14)
- [ ] Deep sweep (Z14): set Config.Backups.holdAfterFailedRestore = false and make a restore fail: the toast, the
  console and the banner say the hold ends at the next restart. (Z14)
- [ ] Deep sweep (Z14): with the waitlist on, a full department in a Cross-Department Mission is refused without
  "Join the waitlist"; a supervisor action on another department says it belongs to another department. (Z14)
- [ ] Deep sweep (Z14): a supervisor pushes a mission to a SAST leader who then joins an FIB unit: that unit cannot
  claim it. (Z14)
- [ ] Deep sweep (Z14): a players_only mission held a volunteer at the accept: he is the one asked, and a second
  players_only accept at the same moment does not take him. (Z14)
- [ ] Deep sweep (Z14): Settings help for Cash.dailyCap says feature rewards count too; with suspect pay on, the
  volunteer consent says a fair case is paid. (Z14)
- [ ] Bug sweep (H2): plan a season end (Admin UI -> Boards -> Seasons) with a next season name, stop the server
  across the date's reset hour and start it again: a few seconds after start the season has ended and the next one
  runs. (H2)
- [ ] Bug sweep (H2): Admin UI -> Money -> Payments -> Retry all pending: the first click only turns the button into
  "Click again to pay all pending"; the second click pays. (H2)
- [ ] Bug sweep (H2): change your look (Edit profile -> Look) with the tablet open, then switch "Use my tablet look on
  the HUD" off and on: the HUD and toasts use the new look, not the old one. (H2)
- [ ] Bug sweep (H2): a second supervisor (no builderEditAny) cannot see or check another supervisor's unpublished
  Mission Builder draft. (H2)
- [ ] Money safety (H3): with Config.Cash.source = 'society' and Pay the rest on, stop Renewed-Banking and press Pay
  the rest on a capped row: nothing is paid and the department is not charged; start it again and Pay the rest works.
  A row marked Check in Admin UI -> Money -> Payments (filter Stuck) opens Resolve with its own buttons, and the
  Payments badge counts it. (H3)
- [ ] Money safety (H3): Take back $100 from a society-paid row while Renewed-Banking refuses deposits: the officer's
  bank drops by $100, the row shows Check (owed to the department); start Renewed-Banking again and wait 10 minutes
  (or press Retry give-back): the department gets the $100 back. (H3)
- [ ] Money safety (H3): a Pay again whose department withdrawal went through but the deposit failed: press Pay again
  once more: only the deposit runs, the department is not charged again. (H3)
- [ ] Money safety (H3): Pay now, Forfeit now and Cancel payment each write their audit row (Admin UI -> Audit) before
  anything changes. (H3)
- [ ] Money safety (H3): Add funds shows "Sending (check it)" for a deposit Renewed-Banking failed half way, and a
  funding row cut by a restart before its deposit shows Failed after the start. (H3)
- [ ] Money safety (H3): with surrender rewards on, restart the server right as an officer talks a suspect down: after
  she logs in again the reward is paid once. (H3)
- [ ] Money safety (H3): take back a two-item reward when only one is still in the inventory: the reply says one is
  left and Admin UI -> Audit shows a second Item taken back row "partial:-1". (H3)
- [ ] Timers and holds (H4): void a run of an officer, then suspend him for 7 days (Admin UI -> Officers). Two days
  later his held cash and items are still held (Admin UI -> Money -> Payments). Lift the suspension: he can file a
  dispute on that run for 48 h from the lift. (H4)
- [ ] Timers and holds (H4): start a backup restore that fails (or a storage copy) 40 h after a void and restart
  10 h later: the voided row is not forfeited at the start, and its officer can still dispute it for the 8 h he had
  left. (H4)
- [ ] Timers and holds (H4): Admin UI -> Live -> reclassify a free real-call abandon from many hours ago, then restart:
  the officer's mission and type cooldowns from the reclassify are still on the board. (H4)
- [ ] Timers and holds (H4): a supervisor resets a Mission control, the server restarts within 5 minutes: setting or
  resetting the same control at once is refused with the change wait. (H4)
- [ ] Timers and holds (H4): two runs flagged on Saturday and Sunday, a run counted on Monday, then both approved: the
  officer's streak on the Home screen counts every day, as if nothing was held. (H4)
- [ ] Timers and holds (H4): a medal EVOC test run with "timer starts at checkpoint 1": press Pause in the test
  controls, then cross checkpoint 1: the timer stays paused until you press Resume. (H4)
- [ ] Timers and holds (H4): Admin UI -> Restrictions: extend a real-suspect pair block, then restart: it keeps the
  new end. With the database stopped the extend is refused ("Something went wrong") and nothing is audited. (H4)
- [ ] Security and anonymity (H5): set Recognition -> commendations -> announce on, turn Hide name on for an officer with
  no callsign, then commend him: the board channel in Discord shows "Hidden officer" (the hidden name), never his
  real name or citizen id. (H5)
