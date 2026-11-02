# Crimson-Police workflows and the specs that drive them

Every workflow an officer, a supervisor or an admin goes through, and the end-to-end spec that drives it start to
finish on the real server side of Crimson-Police (every `modules/**/server.lua` and `blocks/**/server.lua` loaded as in
game; only the other resources and the natives are stubs). The specs run in files mode (database off, the saves
folder, as shipped) with every switch the workflow needs turned on through the Admin UI's own Settings action, and
`tests/storage_copy_spec.lua` and the shadow suite cover where the database differs. Run one with
`lua5.4 tests/run.lua tests/<spec>.lua`; `bash tools/check_all.sh` runs them all.

"Restart" means `restart Crimson-Police` in the middle (onResourceStop, every handler and table gone, every server
file loaded again from the same saves folder, the players still online). "Drop" means the player's game quits
(`playerDropped`) and he comes back later (Qbox's player loaded).

| Workflow | Spec file | Steps covered | Result |
|---|---|---|---|
| Admin Settings, Features, Rewards, an extra grant | tests/workflows_full_spec.lua (1) | Settings opened, the Features tab lists the switch, a supervisor refused, item rewards toggled on, the Rewards pools edited, an extra grant (mission calls for one officer), the hourly cap, a season started; **restart**: every change kept | Pass |
| Patrol mission (Beat Patrol) | tests/workflows_e2e_spec.lua (2) | Accept, Active Mission, every checkpoint, result card, $250, XP, item reward given, a second pay refused | Pass |
| Training mission (EVOC) | tests/workflows_full_spec.lua (2) | Accept, take the wheel, two checkpoints, **restart** (no row, pay, XP or cooldown, per SPEC), accept again, every checkpoint, result card with $350 and the item, paid row, XP | Pass |
| Investigation mission (Suspicious Activity) | tests/e2e_spec.lua (13) | Accept, the contact scene, the police actions and decision, the row | Pass |
| Tactical mission (Gang Shootout), solo and SAST + FIB unit | tests/e2e_spec.lua (2), tests/workflows_e2e_spec.lua (3) | Accept, every wave, secure, tag and bag, release, Reinforced tier, cross-department x1.10, $920, items | Pass |
| Raids, traffic stops, parking patrol, downed officer, flagged run | tests/e2e_spec.lua (4, 7, 11, 12, 14) | Each block's objective to the row | Pass |
| Weekly Boss | tests/workflows_full_spec.lua (3) | The board's boss card on a Friday, the leader accepts, the partner's ready check answered by him, both arrive, **drop** of the partner mid-fight (his row Failed, no cash, the boss cooldown, his weekly attempt spent), reconnect (not back on the run or in the unit), the crew and the Kingpin down, scene secured, $2,500 and 500 points at the Standard pay tier; **restart**: both attempts stay spent | Pass |
| Unit: invite, ready check, promote, kick, leave | tests/workflows_full_spec.lua (4), tests/e2e_spec.lua (16) | An invite declined, a unit of three, a ready check one member declines (no run, no cooldown), the lead handed over, a kick refused for the old leader and done by the new one, **restart** (the unit is gone, per README 11), formed again, leave (a unit of one dissolves) | Pass |
| Cross-Department Mission (sup:opLaunch) | tests/workflows_full_spec.lua (5), tests/teams_spec.lua | An officer refused, the SAST supervisor launches, a SAST officer joins, **restart** (the operation cancelled, the launch wait kept), the admin launches inside the wait with a reason, a joiner **drops** (off the join list) and reconnects, SAST and FIB join, Start now (only the launcher), Gang Shootout to the paid rows with the cross-department bonus, the operation completed | Pass |
| Mission call: create and claim | tests/workflows_full_spec.lua (6), tests/workflows_e2e_spec.lua (4), tests/e2e_spec.lua (15) | The officer with the extra grant creates a call, Dispatch lists it, **restart** with it open (gone, row Lapsed), a new call claimed, **restart** with it claimed (run dropped, no row, call row closed: Ended by a restart), the claim race and re-dispatch | Pass (after fix 1) |
| Goals and the department challenge | tests/workflows_full_spec.lua (7) | A completed run counts in the daily and weekly goal; the season's challenge gives SAST points from its completed runs | Pass |
| Happy hour | tests/workflows_full_spec.lua (7), tests/happy_hour_spec.lua | EVOC on cooldown, an officer refused, the supervisor starts 10 minutes, **restart** (still running, per SPEC), EVOC again at once and paid, over after 10 minutes | Pass |
| Type of the Day | tests/workflows_full_spec.lua (7), tests/dept_tod_spec.lua | The admin switches the control on, the supervisor picks Training for tomorrow, **restart** (today's type unchanged), the next day SAST has Training (the setter keeps the server's), the EVOC row carries the multiplier | Pass |
| Supervisor Mission controls | tests/workflows_full_spec.lua (8), tests/workflows_e2e_spec.lua (5) | Every control switched on by the admin, every number and choice control of SAST set inside its bounds, **restart** (each kept), each reset to config.lua; the hourly cap and its bounds; a cooldown clear | Pass |
| Supervisor actions and awards | tests/workflows_full_spec.lua (8), tests/workflows_e2e_spec.lua (5) | Mission ban (refused accept, **restart** keeps it, lifted), abandon with the type cooldown, a department notice; Give points with its money and item, a commendation | Pass |
| Review, void, dispute | tests/workflows_e2e_spec.lua (6) | A flagged run held, approved (cash and items released once), voided, disputed and restored | Pass |
| Corrections | tests/workflows_full_spec.lua (9), tests/admin_control_e2e_spec.lua (1) | Give points, void a run (XP down), **restart** (still voided), restore (XP back, cash never taken back); retire and unretire | Pass |
| Backups and restore | tests/workflows_full_spec.lua (10), tests/admin_control_e2e_spec.lua (4), tests/admin_backup_spec.lua | Backup, a payment after it, preview, RESTORE, no new run until the restart, **restart**: the payment stays paid, nothing paid twice, runs start again | Pass |
| Storage copy | tests/workflows_full_spec.lua (12), tests/storage_copy_spec.lua | The saves folder copied into MariaDB (every run row, the XP, the Builder missions), the folder in use unchanged, runs start at once; the switch, force and both directions in storage_copy_spec | Pass |
| Mission Builder | tests/workflows_full_spec.lua (11), tests/admin_control_e2e_spec.lua (2), tests/builder_server_spec.lua | A supervisor creates a mission from EVOC, edits and saves it, **restart** (the draft kept, not playable), a test run (pays nothing), publish, **restart** (still plays), an officer draws it and is paid the Training payout | Pass |
| Live crime, backup join, talk-down, booking | tests/live_fto_e2e_spec.lua (2, 3), tests/realsuspects_e2e_spec.lua (2, 4) | LIVE call, claim, scene secured, a backup joins, detain, book, talk-down with its money and item, End case, the rows; **restart** mid-case (case and run end with no row, closed cases kept) | Pass |
| Volunteer by the criminal tablet | tests/realsuspects_e2e_spec.lua (3, 5, 6) | `/crimsonheat` and the criminal tablet, the pop-up, the yes, engaged, the knock, the cuff, volunteerEnded, a strike after the free seconds | Pass |
| Surrender | tests/live_fto_e2e_spec.lua (2, 3) | `/surrender` and Talk them down, the yes, the cuff, Peaceful arrest, the feature reward; **restart** ends a surrender in progress | Pass |
| Field training (FTO) | tests/live_fto_e2e_spec.lua (4) | Pair, a counted run, sign-off, badge, trainer bonus, both payments; **restart**: the training record stays | Pass |
| Resource stop mid-run | tests/e2e_spec.lua (9) | Every mission entity and alert flag removed, no row, pay, audit or cooldown | Pass |

## Defects found and fixed

1. Mission call rows left open for ever by a restart (`modules/missioncalls/server.lua`). Calls live in memory, so
   after `restart Crimson-Police` a call that was open stayed `open` in `cp_mission_calls`, and a claimed call whose
   run the restart dropped stayed `claimed`: the Supervisor UI's calls of today and the dispatch history showed them
   open or claimed for ever. `CP.MissionCalls.closeLeftover()` now runs once at start: open rows become `lapsed`,
   claimed rows become `closed` with the outcome `restart` ("Ended by a restart"). Failing check without the fix:
   `tests/workflows_full_spec.lua` "restart: ...and its row is lapsed, not open for ever" (got open) and
   "restart: its row is closed, not claimed for ever" (got claimed).
