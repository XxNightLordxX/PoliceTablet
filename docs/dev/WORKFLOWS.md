# Crimson-Police workflows: how they work and the specs that drive them

Every workflow an officer, a supervisor or an admin goes through, and the end-to-end spec that drives it start to
finish on the real server side of Crimson-Police (every file of fxmanifest's server_scripts loaded as in
game; only the other resources and the natives are stubs). The specs run in files mode (database off, the saves
folder, as shipped) with every switch the workflow needs turned on through the Admin UI's own Settings action, and
`tests/storage_copy_spec.lua` and the shadow suite cover where the database differs. Run one with
`lua5.4 tests/run.lua tests/<spec>.lua`; `bash tools/check_all.sh` runs them all.

"Restart" means `restart Crimson-Police` in the middle (onResourceStop, every handler and table gone, every server
file loaded again from the same saves folder, the players still online). "Drop" means the player's game quits
(`playerDropped`) and he comes back later (Qbox's player loaded).

**Two city setups.** `tests/workflows_full_spec.lua` runs with the owner's scripts (sc-dispatch, sc-ambulance,
Renewed-Banking and sc-police running), and `tests/workflows_none_spec.lua` runs the very same walk on a city with none
of them (and none of ps-dispatch, qbx_ambulancejob or qbx_policejob): their exports fail, and the admin sets every
`Config.Integrations` kind to `none` in Settings first. Every workflow there ends with the same rows, pay and state;
the one difference checked is that a payout gets no bank history entry without a banking script.
`tests/workflows_none_dispatch_spec.lua`, `_ambulance_`, `_banking_` and `_police_spec.lua` run the same walk once
more for each kind on its own: the owner's four scripts installed, only that one `Config.Integrations` kind set to
`none` in Settings (the other three keep the owner's script), with the same results.

**Every screen.** `Crimson-Police/web/src/layouts/everyScreen.walk.ts` (the `walk` gate step) opens each tablet
from its browser-mock session (Officer, Supervisor, and Admin with every admin power the server gives an admin),
checks that every screen of the registry shows, renders each one with its providers (no error card, its title in the
locale), checks that every request a screen sends has a mock that answers it, and renders each criminal tablet screen.

| Workflow | Spec | Restart | Drop and reconnect | No scripts | Result |
| --- | --- | --- | --- | --- | --- |
| Patrol mission | workflows_e2e (2) | e2e (9) | the solo drop of Training (same run code) | Training, full (2) | Pass |
| Training mission (EVOC) | full (2) | yes | the officer mid-run: Failed, no cash, cooldown | yes | Pass |
| Investigation, tactical, raids, traffic, parking, downed | e2e (2, 4, 7, 11-14), workflows_e2e (3), full (13) | e2e (9) | each block, full (13) | full (13) | Pass |
| Weekly Boss | full (3) | yes | the partner mid-fight | yes | Pass |
| Unit | full (4), e2e (16) | yes | the leader: the lead passes on | yes | Pass |
| Mission call | full (6), workflows_e2e (4), e2e (15) | yes (open and claimed) | the claimer on its run: call closed, Failed | yes | Pass |
| Goals and the challenge | full (7) | yes | - (counted from the rows) | yes | Pass |
| Live crime, backup, talk-down, booking | live_fto_e2e (2, 3, 5), realsuspects_e2e (2, 4) | yes | a suspect and the partner | off (needs a police script) | Pass |
| Surrender | live_fto_e2e (2, 3) | yes | live_fto_e2e (5) | off (needs a police script) | Pass |
| Cross-department mission | full (5), teams | yes | a joiner | yes | Pass |
| Happy hour | full (7) | yes | the supervisor who started it | yes | Pass |
| Type of the Day | full (7) | yes | the supervisor after his pick | yes | Pass |
| Mission controls, push, "+ minutes" | full (8, 8B), workflows_e2e (5) | yes | the supervisor; the partner on the pushed run | yes | Pass |
| Supervisor actions and awards | full (8), workflows_e2e (5) | yes | the barred officer (the ban stays) | yes | Pass |
| Review, void, dispute | workflows_e2e (6) | full (9) | the reviewer with the queue open; the officer while his dispute is decided | corrections, full (9) | Pass |
| Mission Builder | full (11), admin_control_e2e (2) | yes | the supervisor in his test run | yes | Pass |
| Field training | live_fto_e2e (4, 5) | yes | the rookie mid-run, the trainer before sign-off | owner stack only | Pass |
| Volunteer by the criminal tablet | realsuspects_e2e (3, 5-7) | yes | the volunteer and the partner | off (needs a police script) | Pass |
| Settings, Features, Rewards, grant | full (1) | yes | the admin half way through | yes (Other scripts set to none) | Pass |
| Corrections | full (9), admin_control_e2e (1) | yes | the officer offline for the void and restore | yes | Pass |
| Backups and restore | full (10), admin_control_e2e (4) | yes | the admin before the restart (the lock holds) | yes | Pass |
| Storage copy | full (12), storage_copy | - | the admin after the copy | yes | Pass |
| Every tablet screen | everyScreen.walk.ts | - | - | - | Pass |

"full" = tests/workflows_full_spec.lua, "none" = tests/workflows_none_spec.lua (the same sections, no scripts), "e2e"
= tests/e2e_spec.lua. Live crimes, volunteers and surrender need a police script's cuff and jail events, so on a city
with none they stay off (Settings -> Features says why; tests/integrations_spec.lua) and are driven with the owner's
stack only.

The workflows are grouped by who does them: **Officer**, **Supervisor**, **Field training**, **Criminal**,
**Admin** and **System** (what the resource does on its own). Each group's screens sit in the matching tablet: the
Officer UI (`/CrimsonPolice`), the Supervisor UI (the switch in the Officer UI header, for supervisors; its sidebar
grouped under People, Missions and Rewards), the
criminal tablet and the Admin UI (`/CrimsonPoliceAdmin`, its sidebar grouped by play). Every screen of a workflow
has a one-line help under its title that says what to do next, and every error it can show says what went wrong
and what to do about it (tests/workflow_errors_spec.lua holds every err.* text to that).

Each workflow has a short **How it works** paragraph for owners and staff, the spec that drives it, its result, and
how few steps it takes (counted in tablet requests to the server, fixed waits and the player's clicks). Anything that
changes what players see is a Config option; a pure speed-up is on for everyone. The typed RESTORE, REPLACE, SWITCH,
USE and ENABLE words and the reason on every correction stay on purpose (risky or audited actions).

## Officer

### Patrol mission (Beat Patrol)

How it works: on the Mission Board the officer (or his unit's leader) presses Accept on a card. The route to the start
shows on the GPS; at the start the HUD lists the checkpoints and Active Mission shows the same. Each checkpoint
reached ticks off by itself. At the end the result card shows the points, the cash and any item, and the row lands in
his Profile.

Spec: tests/workflows_e2e_spec.lua (2). Covers: Accept, Active Mission, every checkpoint, result card, $250, XP, item
reward given, a second pay refused. Result: **Pass**.

Steps: Accept is one click (one request), the run view arrives by push (no polling while on
a run), the result card comes on its own.

### Training mission (EVOC)

How it works: the same as a patrol, with a vehicle to take: the officer gets in, drives the checkpoints in order and
is paid the Training payout. A restart of Crimson-Police mid-run drops the run with no row, pay or cooldown, so he can
simply accept again.

Spec: tests/workflows_full_spec.lua (2). Covers: Accept, take the wheel, two checkpoints, **restart** (no row, pay, XP
or cooldown, per SPEC), accept again, every checkpoint, result card with $350 and the item, paid row, XP; **drop**
mid-run (his row Failed, no cash, EVOC on its cooldown, back on no run). Result: **Pass**.

### Investigation mission (Suspicious Activity)

How it works: at the scene the officer talks to the contact, picks the police actions offered and makes a decision;
the decision is graded and the row says how it went. Business Check style missions add a tablet log: Active Mission
shows the point and its choices, one click logs it.

Spec: tests/e2e_spec.lua (13). Covers: Accept, the contact scene, the police actions and decision, the row. Result:
**Pass**.

Steps: The tablet log had a fixed 600 ms wait and a second getRun request after each log; now the server
pushes the next point at once and the log is one request with no wait (before: 2 requests + 600 ms per point; after: 1
request, 0 ms).

### Tactical mission (Gang Shootout), solo and with a unit

How it works: accept, drive to the area, clear every wave, secure the scene, tag and bag the evidence and release. A
unit from two departments gets the cross-department bonus; the tier (Standard, Reinforced, ...) follows the number of
officers.

Spec: tests/e2e_spec.lua (2), tests/workflows_e2e_spec.lua (3). Covers: Accept, every wave, secure, tag and bag,
release, Reinforced tier, cross-department x1.10, $920, items. Result: **Pass**.

### Raids, traffic stops, parking patrol, downed officer, flagged run

How it works: each of these is one mission block with its own objective (breach and clear, stop and check, ticket,
revive, ...); the HUD names what to do next and the row records the result.

Spec: tests/e2e_spec.lua (4, 7, 11, 12, 14), tests/workflows_full_spec.lua (13). Covers: Each block's objective to
the row; **drop** mid-run in each block (Suspicious Activity, Drug Lab Raid's unit partner, Traffic Enforcement,
Parking Patrol: his row Failed, no cash, the mission's cooldown, back on no run, the raid goes on for the leader) and a
downed officer who quits before the pick-up (one Downed row, nothing more after the reconnect). Result: **Pass**.

### Weekly Boss

How it works: on its day the board shows the boss card. The unit leader accepts, every member answers the ready check,
the unit drives in and takes the crew and the boss down. Each officer has one weekly attempt; a player who drops
mid-fight loses his and gets no pay.

Spec: tests/workflows_full_spec.lua (3). Covers: The board's boss card on a Friday, the leader accepts, the partner's
ready check answered by him, both arrive, **drop** of the partner mid-fight (his row Failed, no cash, the boss
cooldown, his weekly attempt spent), reconnect (not back on the run or in the unit), the crew and the Kingpin down,
scene secured, $2,500 and 500 points at the Standard pay tier; **restart**: both attempts stay spent. Result:
**Pass**.

Steps: The ready check is pushed to every member at once and can be answered from the
banner (one click); My options -> Auto-Ready answers it for him.

### Unit: invite, ready check, promote, kick, leave

How it works: on the Unit screen the leader invites officers by name; they accept from the pop-up or the Unit screen.
When the leader accepts a mission every member gets a ready check; one No and nothing starts (nobody gets a cooldown).
The leader can hand the lead over or remove a member; a member leaves with Leave unit.

Spec: tests/workflows_full_spec.lua (4), tests/e2e_spec.lua (16). Covers: An invite declined, a unit of three, a ready
check one member declines (no run, no cooldown), the lead handed over, a kick refused for the old leader and done by
the new one, **restart** (units live in memory, so the unit is gone), formed again, the leader **drops** (the lead
passes on, the two others stay; back, he is in no unit), leave (a unit of one dissolves). Result: **Pass**.

Steps: Every unit change is pushed to all members at once. The unit errors now say what to
do ("The unit is full. Its leader can remove a member to make room", "You are not in a unit. Form one on the Unit
screen first").

### Mission call: claim and decline

How it works: Dispatch lists the mission calls open for the officer's unit, nearest first. The leader presses Claim
(one click with My options -> Dispatch -> skip the claim dialog), the server ranks every claim of the claim window by
distance, the unit gets a ready check and the run starts. A mission a supervisor pushed to the unit can be declined.

Spec: tests/workflows_full_spec.lua (6), tests/workflows_e2e_spec.lua (4), tests/e2e_spec.lua (15). Covers: The
officer with the extra grant creates a call, Dispatch lists it, **restart** with it open (gone, row Lapsed), a new
call claimed, **restart** with it claimed (run dropped, no row, call row closed: Ended by a restart), the claimer
**drops** on the call's run (the call row closed with outcome Failed, off Dispatch, not back after the reconnect), the
claim race and re-dispatch. Result: **Pass (after fix 1)**.

Steps: Decline answered and then Dispatch asked the server again; now the reply carries the new Dispatch view
(before: 2 requests; after: 1). Claim errors now name the next step ("Another unit took this call. Pick another call
on Dispatch").

### Goals and the department challenge

How it works: every completed run counts toward the officer's daily and weekly goals (Home) and his department's
challenge of the season (Challenge). Nothing to press: the counts move by themselves.

Spec: tests/workflows_full_spec.lua (7). Covers: A completed run counts in the daily and weekly goal; the season's
challenge gives SAST points from its completed runs. Result: **Pass**.

### Live crime, backup join, talk-down, booking

How it works: a LIVE call is a crime in progress. A unit claims it, secures the scene, other officers can join as
backup, suspects are detained, talked down or booked, and End case closes it; each officer's row records his part.

Spec: tests/live_fto_e2e_spec.lua (2, 3, 5), tests/realsuspects_e2e_spec.lua (2, 4). Covers: LIVE call, claim, scene
secured, a backup joins, detain, book, talk-down with its money and item, End case, the rows; **restart** mid-case
(case and run end with no row, closed cases kept); a suspect **drops** and reconnects within the grace (still in the
case, detained), the partner **drops** (his own row at once, no cash, the case goes on, back on no run). Result:
**Pass**.

Steps: The case card is pushed to every officer on it.

### Surrender

How it works: a player who types `/surrender` (or a suspect that gives up) can be talked down: the officer picks Talk
them down, the player says yes, the officer cuffs him and the arrest counts as peaceful, with the feature reward.

Spec: tests/live_fto_e2e_spec.lua (2, 3). Covers: `/surrender` and Talk them down, the yes, the cuff, Peaceful arrest,
the feature reward; **restart** ends a surrender in progress. Result: **Pass**.

## Supervisor

### Cross-Department Mission

How it works: a supervisor opens joining for one mission (Supervisor UI -> Cross-department). Officers of every
department see it on the board and join; when enough have joined the launcher presses Start now. Only the launcher or
an admin can start it; a restart cancels it and keeps the launch wait.

Spec: tests/workflows_full_spec.lua (5), tests/teams_spec.lua. Covers: An officer refused, the SAST supervisor
launches, a SAST officer joins, **restart** (the operation cancelled, the launch wait kept), the admin launches inside
the wait with a reason, a joiner **drops** (off the join list) and reconnects, SAST and FIB join, Start now (only the
launcher), Gang Shootout to the paid rows with the cross-department bonus, the operation completed. Result: **Pass**.

Steps: Joins are pushed to the panel and the board at once.

### Happy hour

How it works: a supervisor starts a happy hour (for example 10 minutes); while it runs mission cooldowns are lifted
for his department. One per day, it survives a restart, and it ends on its own.

Spec: tests/workflows_full_spec.lua (7), tests/happy_hour_spec.lua. Covers: EVOC on cooldown, an officer refused, the
supervisor starts 10 minutes, he **drops** (it runs on), **restart** (still running, per SPEC), EVOC again at once
and paid, over after 10 minutes. Result: **Pass**.

Steps: Its error now says when to try again ("A happy hour is already running. Start
another one after it ends").

### Type of the Day

How it works: with the admin's control on, a supervisor picks tomorrow's mission type for his department; that type
pays the Type of the Day multiplier the next day.

Spec: tests/workflows_full_spec.lua (7), tests/dept_tod_spec.lua. Covers: The admin switches the control on, the
supervisor picks Training for tomorrow, **restart** (today's type unchanged), the next day SAST has Training (the
setter keeps the server's), the EVOC row carries the multiplier. Result: **Pass**.

### Mission controls

How it works: Supervisor UI -> Mission controls lists the controls an admin switched on, in groups (delays, the run,
the board, calls, officers, department), each with one line saying what it does. The supervisor sets a value inside
the admin's limits or resets it to config.lua; a cooldown clear needs a reason.

Spec: tests/workflows_full_spec.lua (8, 8B), tests/workflows_e2e_spec.lua (5). Covers: Every control switched on by
the admin, every number and choice control of SAST set inside its bounds, **restart** (each kept), each reset to
config.lua; the hourly cap and its bounds; a cooldown clear; pushMission (the Page dialog's missions, the push to a
unit, only that unit sees it, its accept with no draw, audited) and "+ minutes" (addRunTime on the running pushed
mission, the unit told, audited, an officer refused), the partner **drops** (the run goes on with the minutes), the
supervisor **drops** after the sweep (back, every value shown as he set it), then a **restart** (the run and the push
gone). Result: **Pass**.

Steps: Posting, paging, pushing or withdrawing a mission call, Recall and "+ minutes" on Live Missions were answered
and then the screen asked again; now the reply carries the fresh panel or Live Missions view (before: 2 requests;
after: 1).

### Supervisor actions and awards (Department Report)

How it works: Department Report lists the department's officers. Per officer the supervisor can Give points (with a
reason), set or lift a Mission ban (hours and a reason), clear a cooldown (a reason) or give a commendation; a
department notice goes to everyone on duty.

Spec: tests/workflows_full_spec.lua (8), tests/workflows_e2e_spec.lua (5). Covers: Mission ban (refused accept,
**restart** keeps it, lifted), abandon with the type cooldown, a department notice; Give points with its money and
item, a commendation. Result: **Pass**.

Steps: Give points, Mission ban (set or lift), a commendation (give or revoke) and Clear cooldown were answered and
then the dialog asked again; now the reply carries the officer's fresh activity or cooldown list (before: 2 requests;
after: 1). The Give points, Mission ban and Clear cooldown dialogs open with the points, hours and reason last used
on that tablet, so a second award or ban in a row is open + submit (before: open, type 2 fields, submit; after:
open, submit). An empty
reason now reads "Enter a reason in the Reason box first".

### Review, void, dispute (Review Queue)

How it works: Supervisor UI -> Review Queue lists the runs the server held for review (flagged) and the officers'
disputes. The supervisor opens one, presses Approve (the held cash is paid once) or Void, with a reason; a dispute is
approved or rejected the same way. A department can ask for a second supervisor's Void.

Spec: tests/workflows_e2e_spec.lua (6). Covers: A flagged run held, the reviewer **drops** with the queue open (back,
the run is still there), approved (cash and items released once), voided, disputed, the officer **drops** while his
dispute is decided, restored and paid once. Result: **Pass**.

Steps: A decision was answered and then the queue was asked for again; now the reply carries the fresh queue
and the row leaves at once (before: 2 requests; after: 1). The other supervisors of that department who have the
Review Queue open get their updated queue at once (tests/oversight_spec.lua), so two supervisors never work the same
row.

### Mission Builder

How it works: a supervisor (or an admin) creates a mission from a built-in one, edits and saves the draft, test-runs
it (a test pays nothing) and publishes it; from then on officers can draw it and are paid its type's payout. A draft
survives a restart and is never playable.

Spec: tests/workflows_full_spec.lua (11), tests/admin_control_e2e_spec.lua (2), tests/builder_server_spec.lua. Covers:
A supervisor creates a mission from EVOC, edits and saves it, **restart** (the draft kept, not playable), he **drops**
in a first test run (it ends, pays nothing, the draft stays), a test run (pays nothing), publish, **restart** (still plays), an officer draws it and is paid the Training payout. Result:
**Pass**.

## Field training

### Field training (FTO)

How it works: a supervisor pairs a rookie with a trainer. Their runs together count toward the training; the trainer
signs off each task, and at the end the rookie gets his badge and the trainer his bonus. The record survives a
restart.

Spec: tests/live_fto_e2e_spec.lua (4, 5). Covers: Pair, a counted run, sign-off, badge, trainer bonus, both payments;
**restart**: the training record stays; the rookie **drops** mid-run (off the run, the run goes on for the trainer
and does not count; back, still in training) and the trainer **drops** before the sign-off (back, the task still
ready, signed off, done). Result: **Pass**.

## Criminal

### Volunteer by the criminal tablet

How it works: a player (not police) opens the criminal tablet with `/crimsonheat` and volunteers. When a mission needs
a suspect he gets a pop-up; on yes he is engaged, the officers come for him, and the volunteer ends with the cuff or
his time. Backing out after the free seconds is a strike.

Spec: tests/realsuspects_e2e_spec.lua (3, 5, 6, 7). Covers: `/crimsonheat` and the criminal tablet, the pop-up, the
yes, engaged, the knock, the cuff, volunteerEnded, a strike after the free seconds; the volunteer **drops** while
engaged and reconnects within the grace (his tablet shows the case again, no strike), the partner **drops** (the
case goes on), the volunteer is detained and History shows it. Result: **Pass**.

Steps: Every criminal tablet action (save roles, renew, stop, the pop-up answer) already
answers with the fresh view in one request, and the free Give up runs out on its own on the page (no polling). Stop
keeps its second click (it ends the volunteer time); the other buttons are one click.

## Admin

### Settings, Features, Rewards, an extra grant

How it works: Admin UI -> Settings holds every config.lua option with its plain-English description; Features switches
whole features on and off; Rewards edits the item pools; an extra grant lets one officer do something his rank cannot
(for example create mission calls). Every change is kept across a restart.

Spec: tests/workflows_full_spec.lua (1). Covers: Settings opened, the Features tab lists the switch, a supervisor
refused, item rewards toggled on, the Rewards pools edited, the admin **drops** half way through (what he saved is
kept; back, Settings opens), an extra grant (mission calls for one officer), the hourly cap, a season started, every
Other scripts choice set to none (tests/workflows_none_spec.lua); **restart**: every change kept. Result: **Pass**.

Steps: A Setting's save reply carries the changed setting and the screen
applies it (no second fetch); Reset all's reply carries the whole Settings view (before: 2 requests; after: 1); the typed ENABLE stays on the money tools (risky). The common Settings errors now say what to do next (for example "That is
not valid JSON. Check the brackets, quotes and commas.", "This is not a Crimson-Police settings export. Paste a file
made by Export in Settings.").

### Corrections

How it works: an admin gives points, voids a run (its XP goes, the cash is never taken back) or restores it, and
retires or unretires an officer; each needs a reason and is audited.

Spec: tests/workflows_full_spec.lua (9), tests/admin_control_e2e_spec.lua (1). Covers: Give points, the officer
**dropped** (offline), void a run (XP down), **restart** (still voided), restore (XP back, cash never taken back), he
reconnects and sees it; retire and unretire. Result: **Pass**.

Steps: Each correction needs its reason and is audited, so the dialog stays
(its rules require it). Void, Restore, Change kind and Flag were answered and then the run, the run list and the
officer were asked for again; now the reply carries all three (before: 3 to 4 requests; after: 1). Its errors now say what to do next (for example "That run is already voided. Use Restore on it
to undo the void.", "That is over your daily adjustment limit. Give fewer points, or try again tomorrow.").

### Backups and restore

How it works: Admin UI -> System makes a backup, previews one and restores it after typing RESTORE. New runs wait
until the next restart; nothing is ever paid twice.

Spec: tests/workflows_full_spec.lua (10), tests/admin_control_e2e_spec.lua (4), tests/admin_backup_spec.lua. Covers:
Backup, a payment after it, preview, RESTORE, the admin **drops** and reconnects, no new run until the restart,
**restart**: the payment stays paid, nothing paid twice, runs start again. Result: **Pass**.

Steps: Backup now, Restore and Delete answered and then the Backups list was asked for again; now each reply
carries the fresh list (2 tablet requests -> 1, a pure speed-up). RESTORE and the typed backup name stay (risky). The
backup errors say what to do next ("Delete an older backup instead.", "Refresh the backups list and pick another
one.").

### Storage copy

How it works: Admin UI -> System copies the saves folder into MariaDB (or back). The folder in use is left as it is
and runs start again at once.

Spec: tests/workflows_full_spec.lua (12), tests/storage_copy_spec.lua. Covers: The saves folder copied into MariaDB
(every run row, the XP, the Builder missions), the folder in use unchanged, the admin **drops** and reconnects
(System -> Storage opens, still the saves folder), runs start at once; the switch, force and both directions in
storage_copy_spec. Result: **Pass**.

Steps: Copy, Switch storage and Use again answered and then the Storage panel was asked for again, and
admin:getStorage allows one read in 5 seconds, so that second read could be refused and leave the panel stale; now each
reply carries the fresh Storage view (2 requests -> 1, never refused, a pure speed-up). The typed REPLACE, SWITCH and
USE stay (risky).

## System

### Resource stop mid-run

How it works: when Crimson-Police stops while missions run, every mission entity and alert is removed and the runs end
with no row, pay, audit or cooldown.

Spec: tests/e2e_spec.lua (9). Covers: Every mission entity and alert flag removed, no row, pay, audit or cooldown.
Result: **Pass**.