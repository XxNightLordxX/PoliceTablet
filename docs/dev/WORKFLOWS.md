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

**Every officer action.** `tests/workflows_officer_spec.lua` drives every workflow and every action an officer
can take on the same world as the full walk (the owner's scripts running), booted on the shipped config: first with
the shipped config, then with the switches on, a restart and a drop and reconnect in the middle of each part, and
every refusal an officer can meet (no permission, wrong department, a cap reached, a feature off, the maintenance
lock). Its sections are named "officer (n)" below. Every built-in mission but the Weekly Boss (full (3)) is accepted
from the Mission Board and played to its result card there; checkpoint routes, interact points and hostile waves are
worked with their real evidence, the other blocks finish through their own completion after their minimum time (the
block specs drive each of their steps).

**Every supervisor action.** `tests/workflows_supervisor_spec.lua` drives every workflow and every action a
supervisor can take on the same world, with a second SAST supervisor and a SAST cadet added: the Department screen's
Today and Officers tabs, every action of an officer's panel (commend and revoke, Give points, Mission ban, Clear
cooldown), every Mission control set inside the admin's limits and refused outside them, the happy hour, the Review
Queue, mission calls and department notices, field training, extra grants for officers who are not supervisors,
department scoping and the self rule, two supervisors at once and the maintenance lock. Each part runs on the shipped
config first where it is on, then with the switches on, with a restart and a drop and reconnect in the middle and
every refusal a supervisor meets. Its sections are named "supervisor (n)" below.

**Every admin action.** `tests/workflows_admin_spec.lua` drives every workflow of the Admin UI's groups on
the same world, with a second admin (a Qbox admin, Config.QboxAdmins), a SAST cadet and a sheriff's deputy added:
opening the Admin UI, Home with its queues and shortcuts and the officer search; People (an officer's page, his
suspension and run controls, departments added, renamed, turned off and on and deleted, desks, permissions and extra
grants); Missions (the mission and location switches, the Mission Builder as an admin, editing and resetting a
built-in, map markers and extra parts with their rules, the testing tools); Money (pay rates, payments and their row
actions, the money tools behind ENABLE, department funds, item rewards); Review (flagged runs, disputes, corrections,
restrictions, the audit log and its export); System (Settings, presets with their preview, storage, the jobs screen,
problems, the first-start setup, backups and restore) and the maintenance lock a restore holds. Each part runs on the
shipped config first, then with the switches on, with a restart and a drop and reconnect in the middle and every
refusal an admin screen meets. Its sections are named "admin (n)" below.

**Every real-player action.** `tests/workflows_realplayers_spec.lua` drives every workflow of live crimes and
volunteer suspects on the same world (the owner's sc-police sends the cuffs and the jail), with two crew members and
two volunteers added: the shipped config first (a reported crime, `/crimsonheat`, the criminal tablet and the staff
screen change nothing), then the switches on through Settings, a live crime from the LIVE call to the pay, the caps,
`/surrender`, the criminal tablet from opting in to every outcome, strikes and their block, the volunteer's pay with
`Config.FeatureRewards.suspect.voidWithRun` off and on, the staff tools on the Restrictions list, and police `none`.
Each part has a restart and a drop and reconnect in the middle and every refusal a player meets. Its sections are
named "realplayers (n)" below.

**Every system workflow.** `tests/workflows_system_spec.lua` drives what the resource does on its own on the
same world: (1) a fresh install (an empty saves folder, the real migrations runner builds every table at start, a run
played and paid, a restart applies nothing twice); (2) every `Config.Integrations` kind with each adapter (dispatch:
sc-dispatch, ps-dispatch, none; ambulance: sc-ambulance, qbx_ambulancejob with and without EMS on duty and with
qbx_medical stopped, none; banking: Renewed-Banking, none; police: sc-police, qbx_policejob, none), each picked in
Settings and kept by a restart; (3) a restart and the maintenance lock in the middle of each money and storage action
(a payout cut off while paying, a pending payment under a restore lock, a restore the server stops part way, a backup
cut off by a stop, a storage copy and a storage switch with its left-behind lock); (4) the clean-up and the daily
backup at the daily reset, held back by the lock; (5) the idle check. `tests/workflows_system_db_spec.lua` runs the
same walk on MariaDB (an empty database built at start, database on), and `tests/workflows_system_generic_spec.lua`
runs the world on `config/examples/generic.lua` copied over config.lua, through its first-start setup. Its sections
are named "system (n)" and "generic (n)" below.

**Every screen.** `Crimson-Police/web/src/layouts/everyScreen.walk.ts` (the `walk` gate step) opens each tablet
from its browser-mock session (Officer, Supervisor, and Admin with every admin power the server gives an admin),
checks that every screen of the registry shows, renders each one with its providers (no error card, its title in the
locale), checks that every request a screen sends has a mock that answers it, and renders each criminal tablet screen.

**Every click in a browser.** `tools/clickthrough.mjs` (the opt-in gate step `clickthrough`, nightly in CI,
docs/dev/TESTING.md) opens the four tablets on the built UI in its browser mock mode and clicks every
screen, tab and button, checking each dialog a button opens. It found three defects, all fixed: (1) the sidebar
did not scroll, so on a 900 or 1080 px high screen the Admin UI's lower groups (Money, Review, System) could not be
reached; it now scrolls; (2) Admin -> Officers crashed on an officer with no badges (Lua sends an empty list as {});
(3) the Running now mocks named officers the Officers mocks did not have. `layouts/clickthrough.walk.ts` keeps (1) to (3)
checked in the gate.

**A random soak across every workflow.** `tests/soak_spec.lua` runs a seeded random driver on the same world
with 12 officers in three departments (SAST, FIB and a BCSO the admin adds in Departments), 2 supervisors, 1 admin
and 2 civilians. For hours of game time it picks random valid and invalid actions of every role: accept, work the
objective, abandon, units (invite, answer, leave, kick, promote, disband, cancel), mission calls (post, claim,
decline), Give points, commend, Mission ban, Clear cooldown, happy hour, the Review Queue, disputes, manual cash and
Add funds, Settings changes, presets, restarts, drops and reconnects, duty toggles, the hourly, daily and weekly
resets, the maintenance lock, the guided tours (done, `/crimsonhelp`, the admin's reset, the Setup checklist on Home)
and opening each tablet. Even seeds turn every switch on first; odd seeds keep the shipped config. After every action
it checks: no player on two runs; every run ends once per player (one runEnded, one ledger row), and at the end
every run has ended (a restart ends the runs it stops, as documented in runs.lua); the cash each character got
equals the cash_paid of his paid and capped rows; no negative XP, pay or funding; the supervisors' per-day caps, the
unit size and the completions an hour are never passed; every CP.Lock key and the maintenance lock are released; no
entity outlives its run by two minutes; no error line and no Lua error; and a wrong role, another department, a
feature off or the maintenance lock never lets an action succeed. On a failure it prints the seed and shrinks the
action list to the shortest one that still fails (child runs replay it). The normal suite runs one seed for about
two simulated hours; `CP_SOAK=1 CP_SOAK_SEEDS=1-24 CP_SOAK_HOURS=6` runs many, and `CP_SOAK_STORAGE=database` runs
it on MariaDB. A run of 24 seeds for 6 simulated hours each in files mode (77,202 actions, 2,923 runs) and 6
seeds for 4 hours on MariaDB: every invariant held, and no defect of the resource was found. What it did find were
gaps in the test world (ox_inventory's item hook, Qbox's GetMetadata and the city's own players, users,
player_vehicles and mdt_dispatch tables were missing there, so those adapters printed error lines the other world
specs hid): the soak fills them in for itself.

**Every workflow on MariaDB, and under load.** Every workflow and end-to-end spec runs on MariaDB (database on) as
well as on the saves folder: `CP_WF_STORAGE=database lua5.4 tests/run.lua tests/<spec>.lua` runs the worlds of
`tests/workflows_full_spec.lua` (full, none and none_*, officer, supervisor, admin, realplayers, system_generic, soak)
and `workflows_e2e`, `live_fto_e2e` and `realsuspects_e2e` there (`e2e`, `admin_control_e2e` and `system_db` already run
on MariaDB in the database suite). Every one passed with the same results as on the saves folder; on MariaDB the full
world's storage copy goes the other way (the database into the saves folder, Replace). The only differences were in the
specs themselves (they expected the saves folder, and read TINYINT 0 where oxmysql gives false), fixed there; no defect
of the resource was found. `tests/load_spec.lua` (in all three suites) then loads the same world: 48 officers in three
departments, 12 runs at once on the shipped config (the 13th refused) and 16 with every switch on (the 17th refused),
4 cross-department operations (one started by its join window's end), a drop and reconnect mid-run, two start
deadlines, a backup during the 16 runs, 200 queued payments (Qbox refusing some officers' pay, the admin's manual cash
to officers who are offline) with a storage copy and a backup while they wait, then the logins and a restart paying
them. It checks: one ledger row per run and participant (none lost, none doubled), the backup and the copy hold every
row, every queued payment paid exactly once, the deadlines and the join window end on time (within 3 s), no error line,
and the harness tick time (CPU ms per step: p95 within 25 ms, p99 within 100 ms, the worst step within 500 ms). Measured
on both stores: p95 about 2 ms, the worst step 60 to 250 ms (a garbage collection on a busy machine).

**Every writing action sent twice at the same moment.** `tests/race_spec.lua` (in all three suites) runs on the
same world with a second SAST supervisor and a second admin. Each action that writes (money, points, caps, bans,
grants, settings, review decisions, restores, mission calls, accepts, units, item rewards, notices, the guided tours)
is sent by two players, or twice by one (a double click), at the same moment with the harness's yield control on
(`H.interleave`: every MySQL call yields after its answer, as oxmysql's await does in game, so the two copies run turn
by turn, one query each). Every case runs on the same starting state: alone (what one copy does), at once (each copy
whole or not at all, never more than one copy's effect per success, exactly one where only one may act), with the
first sender dropping and reconnecting in the middle, under the maintenance lock (both refused, nothing changes), and
cut by `restart Crimson-Police` after up to five spread queries of the first copy (every query with the opt-in
`race-all` step), then the second sent (never a double effect, every part of the effect moves together, and a cut that
did nothing never leaves the action blocked). tests/crash_matrix_spec.lua cuts the server's own money journeys
the same way. The shipped config first where an action is on there, then
the switches on. It found and fixed: (1) two commendations sent at once both passed the issuer's daily limit and the
same-kind wait; (2) two admins reverting one setting change both reverted it; (3) two guided tours finished at once
kept only one, and two admins resetting one character's tours both logged a reset; (4) an action that finished while
its supervisor or admin had dropped was logged as `player:<id>`, so his daily limits (mission bans, Give points) did
not count it and a second one passed. Known and left as they are: a stop between a void or a revoke and its audit row
loses that row (never the void), a stop between a clawback's hold and the money leaves the amount held (never taken
twice), and a pay cut off part way waits as `paying` for an admin's Resolve; a restore cut by a stop is
`workflows_system` (3). `CP_WF_STORAGE=database` runs it on MariaDB (about 13 minutes), `CP_RACE_ONLY=<text>` runs the
cases whose name holds the text, and `CP_RACE_CUTS=n` cuts at more queries.

| Workflow | Spec | Restart | Drop and reconnect | No scripts | Result |
| --- | --- | --- | --- | --- | --- |
| Duty and the tablet: command, key, desk, item | officer (1, 2b) | yes (the item kept) | the officer after the item setting | owner stack only | Pass |
| Every built-in mission from the board, every block | officer (2a, 2c) | officer (2b) | officer (10) | owner stack only | Pass |
| Rewards locker (no room, claimed later) | officer (2d) | yes | the officer with an item waiting | owner stack only | Pass |
| Patrol mission | workflows_e2e (2) | e2e (9) | the solo drop of Training (same run code) | Training, full (2) | Pass |
| Training mission (EVOC) | full (2) | yes | the officer mid-run: Failed, no cash, cooldown | yes | Pass |
| Investigation, tactical, raids, traffic, parking, downed | e2e (2, 4, 7, 11-14), workflows_e2e (3), full (13) | e2e (9) | each block, full (13) | full (13) | Pass |
| Weekly Boss | full (3) | yes | the partner mid-fight | yes | Pass |
| Unit | full (4), e2e (16), officer (5) | yes | the leader: the lead passes on; a member or the leader in the ready check | yes | Pass |
| Mission call | full (6), workflows_e2e (4), e2e (15), officer (6) | yes (open and claimed) | the claimer on its run: call closed, Failed | yes | Pass |
| Goals and the challenge | full (7), officer (3, 8) | yes | - (counted from the rows) | yes | Pass |
| Twists | officer (3) | - | - | owner stack only | Pass |
| Accept refusals (permission, department, caps, feature off, maintenance) | officer (4) | - | - | owner stack only | Pass |
| Me screen and My options | officer (8) | yes | the officer after saving them | owner stack only | Pass |
| Abandon, off duty, logout, job change, downed mid-run | officer (10), e2e (10) | - | each block the full walk leaves out | owner stack only | Pass |
| Live crime, backup, talk-down, booking | live_fto_e2e (2, 3, 5), realsuspects_e2e (2, 4), realplayers (3, 5) | yes | a suspect and the partner | off (needs a police script), realplayers (11) | Pass |
| Live crime caps, pair cooldown, maintenance lock | realplayers (3, 4) | - | - | off, realplayers (11) | Pass |
| Surrender | live_fto_e2e (2, 3), realplayers (5) | yes | live_fto_e2e (5) | off (needs a police script) | Pass |
| Cross-department mission | full (5), teams, officer (7) | yes | a joiner | yes | Pass |
| Supervisor UI: Today, Officers, the officer panel | supervisor (1-3) | yes | the officer, the supervisor | owner stack only | Pass |
| Commend and revoke | supervisor (2, 9) | yes | the commended officer | owner stack only | Pass |
| Give points, Mission ban, Clear cooldown (caps, limits) | supervisor (3), full (8) | yes (the day's counts kept) | the supervisor, the barred officer | owner stack only | Pass |
| Happy hour | full (7), supervisor (4, 9) | yes | the supervisor who started it | yes | Pass |
| Type of the Day | full (7) | yes | the supervisor after his pick | yes | Pass |
| Mission controls, push, "+ minutes" | full (8, 8B), workflows_e2e (5), supervisor (4, 9) | yes | the supervisor; the partner on the pushed run | yes | Pass (after a fix, in its section below) |
| Calls and department notices | supervisor (6), full (6, 8) | yes | the supervisor who posted | owner stack only | Pass |
| Extra grants for non-supervisors | supervisor (8), full (1) | yes | - | owner stack only | Pass |
| Two supervisors at once, maintenance lock | supervisor (9, 10) | - | - | owner stack only | Pass |
| Supervisor actions and awards | full (8), workflows_e2e (5) | yes | the barred officer (the ban stays) | yes | Pass |
| Review, void, dispute | workflows_e2e (6), supervisor (5), admin (5) | full (9), supervisor (5) | the reviewer with the queue open; the officer while his dispute is decided | corrections, full (9) | Pass (after a fix, in its section below) |
| Mission Builder | full (11), admin_control_e2e (2), admin (3) | yes | the supervisor or the admin in his test run | yes | Pass |
| Field training | live_fto_e2e (4, 5), officer (9), supervisor (7) | yes | the rookie mid-run, the trainer before sign-off | owner stack only | Pass (after a fix, in its section below) |
| Volunteer by the criminal tablet | realsuspects_e2e (3, 5-7), realplayers (6, 7, 10) | yes | the volunteer and the partner | off (needs a police script), realplayers (11) | Pass (after a fix, in its section below) |
| Volunteer strikes, block, Clear strikes | realplayers (9) | yes (the strike and the block kept) | - | off, realplayers (11) | Pass (after a fix, in its section below) |
| Volunteer pay, voidWithRun off and on | realplayers (7-9), feature_rewards | yes | - | off, realplayers (11) | Pass |
| Real suspects staff screen, exclude, suspend, pair block | realplayers (3, 10B) | yes | - | off, realplayers (11) | Pass (after a fix, in its section below) |
| Settings, Features, Rewards, grant | full (1), admin (6) | yes | the admin half way through | yes (Other scripts set to none) | Pass |
| Corrections | full (9), admin_control_e2e (1), admin (5) | yes | the officer offline for the void and restore | yes | Pass |
| Backups and restore, the maintenance lock | full (10), admin_control_e2e (4), admin (7) | yes | the admin before the restart (the lock holds) | yes | Pass |
| Storage copy | full (12), storage_copy | - | the admin after the copy | yes | Pass |
| Admin UI, Home, shortcuts, officer search | admin (1) | yes (the shortcuts kept) | the admin with Home open | owner stack only | Pass |
| Officer page, suspension, run controls | admin (2) | yes (the suspension, the day's clears) | the suspended officer | owner stack only | Pass |
| Departments and desks | admin (2) | yes | the admin before the restart | owner stack only | Pass |
| Permissions and extra grants | admin (2), supervisor (8) | yes | the granted officer | owner stack only | Pass |
| Mission and location switches, mission files reload | admin (3) | yes | - | owner stack only | Pass |
| Map markers and extra parts, their rules | admin (3) | yes | - | owner stack only | Pass (after a fix, in its section below) |
| Testing tools | admin (3) | yes | - | owner stack only | Pass |
| Pay rates, Adjust all | admin (4), e2e | yes | - | owner stack only | Pass |
| Payments: Pay now, Mark paid, Cancel, Retry all | admin (4) | yes | the officer while her payment waits | owner stack only | Pass |
| Money tools (ENABLE), department funds | admin (4) | yes | - | owner stack only | Pass (after a fix, in its section below) |
| Item rewards for admins | admin (4) | yes | the officer with rewards waiting | owner stack only | Pass |
| Restrictions, audit log and export | admin (5) | yes | - | owner stack only | Pass |
| Presets, storage panel, jobs, problems, first-start setup | admin (6) | yes | the admin with the setup open | owner stack only | Pass |
| Fresh install: saves folder and MariaDB, migrations | system (1), system_db (1) | yes (nothing applied twice) | an officer before the restart | owner stack only | Pass |
| Generic example config and the first-start setup | generic (1-3) | yes | the admin with the setup open; an added department's officer | owner stack (ambulance set to none in the setup) | Pass |
| Every Config.Integrations kind with each adapter | system (2) | yes (each pick kept) | the officer released by ps-dispatch | each kind none in turn | Pass |
| Restart and maintenance locks in money and storage actions | system (3), system_db (3) | yes (paying, pending, cut restore, switch) | the paid officer during each lock | owner stack only | Pass |
| Clean-up and daily backup jobs | system (4), system_db (4) | yes (before the reset) | the admin before the reset | owner stack only | Pass |
| Idle check | system (5) | yes | - | owner stack only | Pass |
| Guided tours: done, replay, `/crimsonhelp`, the admin's reset, the Setup checklist | training_spec, setup_spec, tours.walk.ts, soak | soak | soak | owner stack only | Pass |
| Random actions of every role across every workflow, with the invariants checked after each | soak (24 seeds x 6 h; MariaDB 6 seeds x 4 h) | yes (random) | yes (random players) | owner stack only | Pass |
| Every workflow and end-to-end spec on MariaDB (database on), compared with the saves folder | the worlds and e2e specs with `CP_WF_STORAGE=database` | yes (each spec's own) | yes (each spec's own) | none, none_* | Pass (same results on both stores) |
| Load: 48 officers, 16 runs at once, 4 operations, 200 queued payments, a backup and a storage copy | load (MariaDB, saves folder, shadow) | yes (with payments waiting) | yes (mid-run, 20 officers offline) | owner stack only | Pass |
| Every writing action sent twice at the same moment by two players or a double click (43 cases), interleaved query by query | race (saves folder in each suite; MariaDB with `CP_WF_STORAGE=database`) | yes (after each of up to 5 queries of the first copy) | yes (the first sender, in the middle) | owner stack only | Pass (after fixes, in its section below) |
| Every tablet screen | everyScreen.walk.ts | - | - | - | Pass |
| Every screen, tab, button and dialog clicked in a real browser (79 screens and tabs of the four tablets) | tools/clickthrough.mjs (npm run clickthrough), clickthrough.walk.ts | - | - | - | Pass (after fixes, in its section below) |

"soak" = tests/soak_spec.lua, "load" = tests/load_spec.lua, "race" = tests/race_spec.lua, "system" = tests/workflows_system_spec.lua, "system_db" = tests/workflows_system_db_spec.lua, "generic" =
tests/workflows_system_generic_spec.lua, "admin" = tests/workflows_admin_spec.lua, "realplayers" = tests/workflows_realplayers_spec.lua, "full" = tests/workflows_full_spec.lua, "none" = tests/workflows_none_spec.lua (the same sections, no scripts), "e2e"
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

### Duty and the tablet

How it works: an officer on duty in a police job opens the Officer UI with `/CrimsonPolice`, the key, a mission desk
or (when the admin names one in `Config.Tablet.item`) the tablet item. Each way can be switched off in
`Config.Tablet.access`; a desk can be kept for some departments; with `requireItem` every way but a desk needs the item
in the pockets, and accepting a mission or claiming a call checks it again. Off duty, out of the job or a civilian:
the tablet is refused with the reason.

Spec: tests/workflows_officer_spec.lua (1, 2b). Covers: the command and the key; the item way off with no item; a desk
at it, away from it and an unknown one; off duty and back; a civilian; the Supervisor UI refused to an officer; the
item named, then required (no item: the command and an accept refused; with it: opens; a desk never needs it); the
command way off; a desk kept for FIB; **restart** (the item setting kept); **drop** and reconnect. Result: **Pass**.

### Every built-in mission, from the Mission Board to the result card

How it works: the board shows each type with its payout; Accept draws one of its missions. Every objective block
(checkpoint route, interact points, field contact, pursuit, search area, flee and arrest, process the scene, escort,
skill check, hostile waves, protect and rescue) ends the run on the result card with the points, the cash and any item,
and the row in the Profile. With no room in the pockets the item waits in the Rewards locker until he claims it.

Spec: tests/workflows_officer_spec.lua (2a, 2c, 2d). Covers: the shipped config (Beat Patrol paid $250, no item, no
type cooldown); with the switches on, every built-in mission but the Weekly Boss (full (3)) accepted from the board
(a unit of two where the mission needs two) to the result card: the row Completed, the card's points and cash equal
the row's, the XP grown by them, at least the type's payout paid once, the item given, not held for review, the
partner's row Completed, the mission on its cooldown; the locker (no room: waiting; a claim refused while still full
and for another officer; **restart** and **drop**: still waiting; room: given once; a second claim refused).
Result: **Pass**.

### Twists, refusals of an accept

Spec: tests/workflows_officer_spec.lua (3, 4). Covers: EVOC with Time Crunch (the run carries it, still made in time,
the pay raised, the card lists it), an unknown twist refused, Home's goals; a civilian and an unknown type; a
department that switched a type off (its officer refused, another department's served); an officer refused a Mission
control; the hourly cap; a type's daily limit; a mission ban and its lift; My options switched off; the maintenance
lock (accept refused, the tablet still opens). Result: **Pass**.

### Abandon, off duty, logout and a job change mid-run

How it works: Abandon on Active Mission ends his part with an Abandoned row and the type's abandon cooldown. Going off
duty does the same (off duty); a logout (character unload) or a quit is a Failed row; a job change takes him off the
run. In a unit the run goes on for the others; the last one leaving ends it.

Spec: tests/workflows_officer_spec.lua (10). Covers: abandon (twice refused, a run he is not on refused); off duty in
progress; a logout and the login after; a drop in search area, flee and arrest, skill check, protect and rescue and a
checkpoint route, and of the escort partner; a unit run where a member and then the leader abandon and the last one
goes off duty; a job change; downed. Result: **Pass**.

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
passes on, the two others stay; back, he is in no unit), leave (a unit of one dissolves).
tests/workflows_officer_spec.lua (5): a civilian neither invited nor inviting, an invite taken back, a member refused
accept, kick and promote, a kick refused on a run, a removed officer not invited again at once, a member and then the
leader **dropping** while the ready check asks (no run, no cooldown, the unit not left locked), the unit full at four,
an invite past its time, Disband. Result: **Pass**.

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
claim race and re-dispatch. tests/workflows_officer_spec.lua (6): an officer refused a post, a member refused claim and
decline, an unknown call, a claimed call claimed again, a pushed mission declined by the leader (the reply carries
Dispatch without it), another accepted and a **restart** (gone, not offered again). Result: **Pass (after fix 1)**.

Steps: Decline answered and then Dispatch asked the server again; now the reply carries the new Dispatch view
(before: 2 requests; after: 1). Claim errors now name the next step ("Another unit took this call. Pick another call
on Dispatch").

### Me screen and My options

How it works: Me shows his Profile (edit it once in a while; report another officer's profile to the supervisors),
the Leaderboard (Hide my name shows the callsign to others) and the Challenge. My options keeps his choices on the
server (favourite types, call pop-ups for favourites only, ...); the HUD options stay on the PC.

Spec: tests/workflows_officer_spec.lua (8). Covers: his profile and another's, an unknown one, Edit profile and the
edit wait, a civilian, a report (twice and his own refused); the leaderboard counting his runs and hiding his name
from another officer; the challenge; options saved, a local option, a wrong value and an empty change refused; call
pop-ups for favourites only and muted; **restart** (options and Hide my name kept); **drop** and reconnect.
Result: **Pass**.

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
launcher), Gang Shootout to the paid rows with the cross-department bonus, the operation completed.
tests/workflows_officer_spec.lua (7): nothing to join, a civilian and a barred officer refused, a second join refused,
other accepts wait while it joins, Leave and join again, a joiner **drops**, a **restart** cancels it. Result: **Pass**.

Steps: Joins are pushed to the panel and the board at once.

### Happy hour

How it works: a supervisor starts a happy hour (for example 10 minutes); while it runs mission cooldowns are lifted
for his department. One per day, it survives a restart, and it ends on its own.

Spec: tests/workflows_full_spec.lua (7), tests/happy_hour_spec.lua. Covers: EVOC on cooldown, an officer refused, the
supervisor starts 10 minutes, he **drops** (it runs on), **restart** (still running, per SPEC), EVOC again at once
and paid, over after 10 minutes. Result: **Pass**.

tests/workflows_supervisor_spec.lua (4, 9): 31 and 4 minutes and a scale the admin does not allow refused, an officer
refused, started for 10 minutes (an officer's and FIB's cooldowns lifted, never the starter's: the self rule), a
second one refused while it runs, the starter **drops** and a **restart** (runs on, still not for him), the self rule
off (it applies to him too), over after 10 minutes, a second one that day refused (perDay 1), an admin may, the next
day a supervisor may again, two supervisors pressing Start together (one runs). Result: **Pass**.

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
gone). tests/workflows_supervisor_spec.lua (4, 8, 9): every control of his department and of the whole server listed;
each number control refused above the admin's max, each other control refused a bad value; each set inside the limits,
the second supervisor then refused for the change wait; his **drop** and a **restart** keep every value; each reset
(a reset of a control not set, an unknown control, an action control and a missing reason refused); an officer has
neither the screen nor a change; a control the admin switched off refused; the master switch off (its controls
refused, the server-wide ones still set); a department's grade rule (SAST from grade 4: refused at grade 3, FIB not
bound, allowed once promoted); the Type of the Day once a day; the same request sent twice saves and audits once; the
other department keeps its own value. Result: **Pass (after the fix below)**.

Fix: a control saved as false (the no-repeat rule switched off) showed as not changed (no "changed by", no
Reset) because the screen's saved value read `row.value or nil`; it now carries the saved false.

Steps: Posting, paging, pushing or withdrawing a mission call, Recall and "+ minutes" on Live Missions were answered
and then the screen asked again; now the reply carries the fresh panel or Live Missions view (before: 2 requests;
after: 1).

### Supervisor actions and awards (Department Report)

How it works: Department Report lists the department's officers. Per officer the supervisor can Give points (with a
reason), set or lift a Mission ban (hours and a reason), clear a cooldown (a reason) or give a commendation; a
department notice goes to everyone on duty.

Spec: tests/workflows_full_spec.lua (8), tests/workflows_e2e_spec.lua (5). Covers: Mission ban (refused accept,
**restart** keeps it, lifted), abandon with the type cooldown, a department notice; Give points with its money and
item, a commendation. tests/workflows_supervisor_spec.lua (1-3): Today (his department's officers on duty and runs
going; an officer refused), Officers (his department only; another department, an unknown one and an officer refused;
an admin any), an officer's panel (not another department's, not an officer's, a bad citizenid). Shipped: Give points
and Mission ban not offered and refused, Clear cooldown offered; commend from the panel (the reply carries the panel),
a citation too short, an unknown kind, himself, another department, the same kind within 7 days, an officer, three a
day (the second supervisor has his own), **restart** and the officer's **drop** (kept), revoke (another supervisor and
no reason refused, the issuer), commendations off and the commend power off. Switches on: Give points 50 (51 and 0
refused, a reason, himself, another department, an officer), 100 a day kept by a **restart** and his **drop**, the
second supervisor's own 100, point adjusts off, the control off (not offered); Mission ban (25 hours, the same grade,
another department, himself, an officer refused), she cannot accept, another supervisor cannot replace or lift it,
her **drop** and a **restart** keep it, lifted by the setter with a reason, three a day, an offline officer, the
Restrictions tab; Clear cooldown (a reason, never all, an unknown type, his own, an officer refused), a FIB agent's
too (server-wide), refused on a run, three a day per officer by all staff kept by a **restart**, five a day per
supervisor. Result: **Pass**.

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
dispute is decided, restored and paid once. tests/workflows_supervisor_spec.lua (5): a SAST flagged run in both SAST
supervisors' queues, not FIB's, no queue for an officer, FIB and the officer refused, a reason needed; a **restart**
and the reviewer's **drop** (still there); approved (the reply carries his queue, the other supervisor's open queue
pushed at once, paid once, his approve of the same row refused); voided; Undo and a batch Undo refused to a
supervisor, the admin's Undo restores it, Undo switched off refused; the department's second Void: the first is
taken and waits, the same supervisor cannot be the second, a **restart**, the other supervisor's Void voids it; the
review power off; his own flagged run never in his queue and approved by the other supervisor. Result: **Pass (after
the fix below)**.

Fix: the first Void waiting for a second supervisor lived in memory only, so a restart forgot it (the queue no
longer said who voided first and the next Void became a first Void again). The start now reads the waiting first
Voids back from the audit log (voidPending rows that are still the newest entry of their row, the last 90 days).

Steps: A decision was answered and then the queue was asked for again; now the reply carries the fresh queue
and the row leaves at once (before: 2 requests; after: 1). The other supervisors of that department who have the
Review Queue open get their updated queue at once (tests/oversight_spec.lua), so two supervisors never work the same
row.

### Calls and department notices

How it works: Supervisor UI -> Dispatch creates a mission call for every unit (a wait between two of his), withdraws
one with a reason or pages a unit. A department notice (the notices Mission control) shows on his department's Home
only, for 1 to 30 days; five may run at once and he may post five a day.

Spec: tests/workflows_supervisor_spec.lua (6). Covers: the panel (not for an officer), a call created (the reply carries
the panel, officers see it), a second at once refused (the staff wait), an unknown type and an officer refused, the
second supervisor's own wait, his **drop** (the call stays), withdraw (a reason, an officer, twice refused), a
**restart** (the open call gone), the power off; a notice (31 days, no text, an officer, a staff notice refused),
posted (SAST Home only, his count of today), a **restart** keeps it, FIB cannot end it, the other SAST supervisor ends
it, five a day, five running at most, the control off. Result: **Pass**.

### Extra grants, department scoping, two supervisors, the maintenance lock

How it works: Admin UI -> Permissions -> Extra grants gives one power to officers who are not supervisors (by
citizenid, or by department from a grade); a power switched off stays off for them too. Config.MissionControls.grants
limits a department's controls to some grades. Two supervisors of one department share its controls (the change
wait), each keeps his own day counts. During a restore or a storage copy every supervisor action waits.

Spec: tests/workflows_supervisor_spec.lua (4, 8, 9, 10). Covers: Mission controls and field training granted to one
trooper (he opens and changes a control, pairs; another trooper cannot), mission calls from grade 1 (a trooper may,
the cadet and FIB may not), a **restart** keeps them, the power off and the master switch off refuse the granted too,
taken back; the grade rule; the same request twice, the change wait between the two, FIB's own value, two happy hours
at once, both giving points (each his own day), the same commendation kind twice; the lock (Give points, Mission ban,
Clear cooldown, a control, a notice, pairing, a commendation, a call and a review decision refused; Today, Officers
and the Review Queue still open; a commendation again after it). Result: **Pass**.

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
ready, signed off, done). tests/workflows_officer_spec.lua (9), as the rookie: he sees his training, a tactical run
alone is refused (requireTrainerFor), he cannot sign himself off, with his trainer in the unit he can, he **drops**
mid-run and is still in training back. tests/workflows_supervisor_spec.lua (7, 8): off as shipped; an officer, a FIB
rookie, the rookie as his own trainer, a trooper below the trainer grade, a FIB trainer and an offline trainer refused;
paired, twice refused, the Training tab lists it (not for an officer); a sign-off before a run together refused; a
**restart** keeps it; the unit's accept of a type with no mission for two (the leader told why after Ready); a run
together, a sign-off by someone else and of a type that is no task refused, the trainer signs off, twice refused;
unpair (an officer refused, twice refused); the feature off; an officer with the extra grant pairs. Result: **Pass
(after the fix below)**.

Fix: when a unit's accept failed after everyone answered Ready (no mission left for the unit, a member barred
or on a call meanwhile, the lock), the leader was never told: his Accept had already answered "ready check sent".
He now gets the reason as a toast (a mission call claim keeps its own messages).

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

### Every real-player action

How it works: with live crimes on, Crimson-Contracts' reported crime is a LIVE card on Dispatch; a unit claims it,
holds the scene, backup joins by its pop-up, suspects are detained, booked or talked down, and End case writes each
officer's row. With volunteers on, a player opts in on the criminal tablet (`/crimtab`) or `/crimsonheat`; when a
mission needs a suspect he is asked first (Jobs), travels to the meet point after his yes, and officers engage him.
Both modes need a police script that reports cuffs and jail (sc-police); without one they stay off with a clear line.

Spec: tests/workflows_realplayers_spec.lua. Covers: (1) as shipped: a reported crime posts no LIVE call,
GetAvailablePolice answers nil, `/crimsonheat` and its menu are refused, the criminal tablet does not open, no Real
suspect badge, the staff screen off and Exclude refused. (2) A supervisor and a civilian cannot change a setting; the
admin turns on live crimes with cash, volunteers for Investigation, the criminal tablet and both feature rewards; the
Real suspects screen for the admin only. (3) The LIVE call (no live position to officers), claims refused to a
civilian, an unknown call and during the maintenance lock, the unit's claim, a second claim refused; backup: the scene
pop-up with no position, No, no second pop-up while one runs, a forged token, the dispatch-response pop-up, Yes, a
second join refused; detain, booking at Mission Row, the talk-down hint, Talk them down and its Yes, Peaceful arrest;
the staff screen and case (refused to a supervisor and for a bad id); End case refused to an officer not on the case,
liveCrimeEnded with no position, the rows with cash, the talk-down paid once, the timeline. (4) The same unit and
crew inside pairCooldownHours cannot claim, another officer can; a downed suspect counts neutralisedShare; the second
LIVE call fits maxLiveRuns, a third does not; maxOfficers full and backup off refuse the join; another department may
join, the officer who caught that crew an hour ago may not. (5) `/surrender` before a case (not wanted), with a case
(his confirm, a forged answer refused, his Yes), Peaceful arrest; a suspect **drops** and is back within the grace,
the partner **drops** (her row at once, no cash, may not join again), the case ends; a **restart** mid-case (no row,
pay, LIVE call; the closed case kept; `/surrender` not wanted; the old crime's end ignored), the next case paid.
(6) The criminal tablet: a civilian opens it, an officer on duty and a police job off duty refused, access granted
with no grant refused, an unknown action and a bad payload refused; Get on the list (no role refused, twice refused),
roles, Renew, Stop (twice refused), Renew and Give up and an answer with nothing to act on refused, the window runs
out, a **drop** and a **restart** empty the list, the maintenance lock refuses the actions while the tablet reads.
(7) Two volunteers: the Real suspect badge, one asked first (no position on the job, the reward line), his No (never
a strike), the next one asked, his Yes, in position, engaged (Give up no longer free), no live position to officers,
detained and booked, nothing left to give up, the time limit, volunteerEnded with no position, $500 paid once, nothing
to the one who said No, History, the staff timeline. (8) voidWithRun off: voiding both officer rows leaves his pay;
on: one void leaves it, both void it, a **restart** keeps it voided, one restore brings it back. (9) Give up within
the free seconds (no strike, History "Called off", nothing paid), got away ($1,500 paid), Give up past the free
seconds (a strike, nothing paid), a **restart** (History still shows the strike), a second strike with two strikes to
a block (off the list, Home shows the block, Get on the list refused, on Restrictions), a **restart** keeps the block,
a supervisor cannot lift it, the admin extends and lifts it (Clear strikes), nothing left to clear. (10) The volunteer
**drops** mid-case and is back within the grace (no strike), then gone past the grace (a strike, History says he
left, nothing paid); a **restart** mid-case (no case, row, pay or strike, he may join again). (10B) Exclude, Suspend
and Block a pair (a supervisor, a bad citizenid and zero days refused), each refusing what it should, all three on
Restrictions, kept by a **restart**, a supervisor cannot lift, the admin lifts each. (11) Police `none`: the switches
stay on but both modes are off, Settings -> Features says why for each, no LIVE call, GetAvailablePolice nil, the
volunteer list empties, `/crimsonheat` refused, the criminal tablet still opens and says volunteers are off, its Get
on the list refused, no Real suspect badge, the staff screen off; sc-police again and everything is back. Result:
**Pass (after the fixes below)**.

Fix: after a restart, a volunteer's criminal tablet History showed none of his saved strikes until he got on
the list again (the strikes were read back under his licence, but the History looked them up only by the key he had
volunteered under in memory). It now finds them by the online player's licence.

Fix: with the police script set to `none` (or one that sends no cuff and jail facts) the criminal tablet still
said volunteers were on, and Get on the list answered "not available". It now says "Volunteer suspects are off on this
server right now", the same as when the switch is off.

Fix: with the police script set to `none`, the GetAvailablePolice export still counted officers although live
crimes were held off; it now answers nil, as documented for live crimes off, so a crime script counts police its own
way.

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

### Every admin action

How it works: the Admin UI (`/CrimsonPoliceAdmin`) opens for the AdminAce admins and, with Config.QboxAdmins, the
Qbox admins; who is an admin comes only from config.lua. Every change is an admin action with its own guards (the
maintenance lock, the permission, a rate, a request id, a reason, a typed word, a preview, never the admin's own
records) and is audited.

Spec: tests/workflows_admin_spec.lua. Covers: (1) the Admin UI for both kinds of admin and refused to a supervisor,
an officer and a cadet, AdminAce and QboxAdmins locked in Settings, Home's on-duty count, runs going, queues and the
shipped five shortcuts, the admin's own shortcuts (a double and an unknown one refused, none, by use) across a
**restart**, the officer search by name, citizenid and department, the admin **drops** with Home open. (2) An
officer's page, a suspension kept by a **restart** and the officer's **drop**, lifted, lifting twice refused; his
cooldowns read and cleared up to the day's limit with a **restart** and his **drop** in between; a department added
from a Qbox job (an unknown job, another department's job and an existing key refused), its deputy opens the tablet,
renamed, a **restart**, turned off (refused while its officer is on a run, the typed tag), on again, a department with
history never deleted, one without deleted; a desk added where the admin stands, a bad size and department refused,
limited to FIB, a **restart**, teleport, removed; a supervisor power off and on, extra grants by citizenid and by
grade, an admin-only power never granted, a **restart**. (3) Beat Patrol switched off (never drawn, a **restart**)
and on, a location off, reset, a mission files reload; the Mission Builder as an admin with testing required for
supervisors (a **drop** in the first test, a test driven through, published, drawn and paid after a **restart**,
archived, restored); EVOC edited, a **restart**, Reset to original with its typed id, editBuiltins off; map markers:
no extra parts as shipped, the partner part on for a unit, a rule naming an unknown part, department or mission type
refused, the leader-only rule kept by a **restart**; the testing tools (a test run ended by the other admin, recorded,
a **restart**, hidden and shown, a location marked checked). (4) Pay rates: Patrol to $400 paid after a **restart**,
a mission payout and its clear, Adjust all with its preview and typed ADJUST; payments: a refused payout pending, Pay
now while the officer is offline, a **restart**, her login pays it, a stuck payment marked paid (Pay again ships off),
a pending one cancelled with its typed amount, Retry all, the export; the money tools refused until ENABLE, a
**restart**, Pay by hand, an unknown citizenid, a clawback; department funds; item rewards waiting, Deliver now
refused while she is offline, a **restart**, one cancelled, the other delivered once. (5) Flagged runs of both
departments in the admin's queue and on Home, a **restart** and the admin's **drop**, approved and voided, the second
admin's approve refused; a dispute (another officer's refused, a second one refused), the officer **drops**, approved
after a **restart**, paid back online; corrections (points with their typed confirm, a void and restore across a
**restart**, a bulk void with its preview and its batch Undo after a **restart**, retire and unretire);
restrictions (lift and extend, a supervisor refused, Extend switched off); the audit log, its export and Save to
server. (6) Settings (bad values, JSON and paths refused, the history, a **restart**, Revert, Reset, the config.lua
only settings, export and a refused import); presets (the preview, an unknown one, Go-live applied, a **restart**,
applied again changes nothing, a city's own preset); the storage panel and Switch's typed SWITCH; the jobs screen
(Run now with a reason, an unknown job, not twice in a row); problems; the first-start setup across a **restart** and
the admin's **drop**, finished with a preset. (7) A backup, RESTORE: the maintenance lock refuses every admin change
(settings, a mission switch, pay, a suspension, points, a desk, a preset, a job, a backup, a test, the Builder) while
every screen still reads and no run starts, the admin **drops**, a **restart** ends the lock. Result: **Pass (after
the fixes below)**.

Fix: Settings -> Config.Markers.rules took a rule for a part, department or mission type that does not exist
(a typo such as `partnr` or `patrl`), and that part then silently never showed for anyone. The rule is now refused
with a message naming what to fix.

Fix: an action on one officer that must never touch the admin's own characters (Pay by hand, giving points
and the other strict ones) answered a citizenid nobody has (a typo) with "This player's licence can't be found". It
now says "No officer with that citizen ID has used Crimson-Police yet. Check the ID and try again."; an officer whose
licence is really unknown keeps the licence message.

## System

### Resource stop mid-run

How it works: when Crimson-Police stops while missions run, every mission entity and alert is removed and the runs end
with no row, pay, audit or cooldown.

Spec: tests/e2e_spec.lua (9). Covers: Every mission entity and alert flag removed, no row, pay, audit or cooldown.
Result: **Pass**.

### Fresh install and the start on MariaDB

How it works: on the first start the migrations runner builds every table in the saves folder (database off, as
shipped) or in the MariaDB database (database on); each later start applies only a migration it has not recorded.
Nothing else is needed before officers use the tablet.

Spec: tests/workflows_system_spec.lua (1), tests/workflows_system_db_spec.lua (1). Covers: the server stopped, the
saves folder (or the database) emptied, started: every migration applied, none pending, the tables there (every MariaDB
table utf8mb4), no lock; the officers online all along open the tablet, a Beat Patrol paid; an officer **drops**, a
**restart**: no migration applied or recorded twice, the run kept, he reconnects. Result: **Pass**.

### The generic example config and the first-start setup

How it works: a city that buys the resource copies config/examples/generic.lua over config.lua: its departments are
qbx_core's police jobs (LSPD, BCSO, SASP, supervising from grade 3), every other script is 'auto', and Admin UI -> Home
opens on the First-start setup until an admin finishes or skips it. The officers can use the tablet meanwhile.

Spec: tests/workflows_system_generic_spec.lua. Covers: (1) a fresh saves folder on the generic config, the setup on
Home with what it found (the three departments, the Qbox police jobs with the city's own ranger job, the saves folder,
the scripts 'auto' found, the presets), refused to a supervisor and an officer, the LSPD officer already opens the
tablet and the ranger cannot, the admin **drops**, a **restart**: still shown. (2) Refused answers (an unknown
department, a job Qbox lacks, an existing department, an unknown colour source) leave it pending; finished with BCSO
supervising from 2, Park Rangers added from its Qbox job (its boss grade), ambulance set to none and the casual preset;
a **restart** keeps it all. (3) An LSPD Beat Patrol paid, the BCSO lieutenant's Department screen, a BCSO officer is no
supervisor, the ranger opens the tablet across his **drop** and a **restart**. Result: **Pass**.

### Every Config.Integrations kind with each adapter

How it works: Config.Integrations picks the dispatch, ambulance, banking and police script ('auto', a script's name or
'none'); a change in Admin UI -> Settings works at once and is kept by a restart. A named script that stops is not
swapped for another one; Config health names it.

Spec: tests/workflows_system_spec.lua (2). Covers: as shipped 'auto' finds the owner's four scripts; a supervisor and a
script with no adapter refused; ps-dispatch: an officer on a run who responds to one of its real calls is released, the
sc-dispatch toggle is ignored, a **restart** and the officer's **drop** keep the pick, ps-dispatch stopped (no
dispatch, still named, Config health says so), none (nobody released); sc-ambulance with no doctor (the free pick-up),
qbx_ambulancejob with EMS on duty (its own EMS request, no pick-up) and without (the pick-up, qbx_medical's revive), a
**restart**, qbx_medical stopped (the pick-up cancelled), none (the pick-up); Renewed-Banking (a bank history entry),
none across a **restart** (paid the same, no history entry, no society account); sc-police (live crimes may run),
qbx_policejob (jailing but no cuffing: live crimes stay off and Features says why; its events are not read with no
case open), a **restart**, none. There is no qbx_management adapter: department money goes through the banking kind.
Result: **Pass**.

### A restart and the maintenance lock in the middle of each money and storage action

How it works: a payout that was cut off while it paid waits as 'paying' for an admin's check and is never paid again
by itself; while a maintenance lock holds (a restore, a storage switch left behind, a copy) every payment, money tool,
backup, copy and new run waits, and the screens still read. A restore the server stops part way comes back locked
(Config.Backups.holdAfterFailedRestore) until a restore works.

Spec: tests/workflows_system_spec.lua (3), tests/workflows_system_db_spec.lua (3). Covers: AddMoney raised (paying),
a **restart** and her **drop** and login pay nothing, Mark paid; a pending payment, a backup, the restore: Pay now,
Retry all, manual cash, a clawback, department funds, a pay rate, a backup and a storage copy each refused with
err.maintenance, her login pays nothing, no run starts, a **restart** ends the lock and pays her once (and a second
restart never twice); a restore stopped part way: the lock is back at start naming its automatic backup, nothing paid,
every money action refused, the fix restore, a **restart**, paid once; part files of a backup cut off by a stop are
never listed and removed at the next start; a storage copy into the other store, a **restart**, a copy over it refused
without force and REPLACE, then replaced; a storage switch (typed SWITCH) whose restart comes back on the old store:
the left-behind lock holds payments, money actions and runs, Use again (typed USE, admins only) lifts it, she is paid
once, audited. Result: **Pass**.

### The clean-up and the daily backup

How it works: at each daily reset (Config.Time.resetHour) the clean-up archives runs older than
Config.Retention.runArchiveMonths and deletes audit rows older than auditDays (0 keeps them); with Config.Backups.daily
a backup is made first and Config.Backups.keep removes the oldest. A maintenance lock holds both back.

Spec: tests/workflows_system_spec.lua (4), tests/workflows_system_db_spec.lua (4). Covers: a **restart** before the
reset, the old run archived and the old audit row deleted, no daily backup as shipped, the Jobs screen's last result;
retention 0 keeps both, the daily backup with keep 2 across the admin's **drop** and a **restart**; under a restore
lock no clean-up and no backup at the reset; the **restart** ends the lock and the next reset cleans up. Result:
**Pass**.

### Idle

How it works: with officers on duty and nobody on a run, the server only posts and lapses the NPC mission calls
(Config.MissionCalls, on as shipped) and sends their cards; with them off it writes and sends nothing. No server thread
waits less than 500 ms.

Spec: tests/workflows_system_spec.lua (5). Covers: ten idle minutes as shipped (only cp_mission_calls written, only
mission call cards sent, the cached officer checks read), then mission calls off and a **restart**: nothing written,
nothing sent. Result: **Pass**.

