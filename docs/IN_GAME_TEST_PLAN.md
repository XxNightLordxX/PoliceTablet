# In-game test plan

A short plan for testing Crimson-Police on a test server, most important first. Session 1 is a 60-minute smoke test
of the parts every officer uses. Session 2 is for the changes most likely to need a second look. Each line says what
you do and, after the arrow, what you should see. When a line does not match, look up the same feature in
[docs/IN_GAME_CHECKLIST.md](IN_GAME_CHECKLIST.md) (one section per feature, with every detail).

## Before you start (5 minutes)

- A **test server**, not the live one, on the shipped `config/config.lua` (Debug on, database off, so everything is
  saved in the `saves` folder), with your normal scripts running.
- One **admin** account (a Qbox admin while `Config.QboxAdmins = true`, or a player with the `crimsonpolice.admin` ace), two **officers** on duty (one SAST, one FIB is best) and one
  **supervisor** (a grade at or above the department's `supervisorGrade`). One person with two characters works too,
  but the unit run needs two players.
- Keep the server console and `resmon` (F8 console: `resmon 1`) open. Write down the numbers you see: they are the
  ones to compare with after an update.

## Session 1: smoke test (60 minutes)

### Start the resource (5 min)

- [ ] Start the server, or `ensure Crimson-Police` -> the console shows the storage line, the saves folder at the
  newest version, `missions loaded: 19 built-in (0 edited), 0 custom, 0 rejected` and the `Start-up check` line. Yellow or red
  lines each name their fix (README 3.4 and 8.3).
- [ ] `CrimsonPoliceAdmin check` in the console -> every check listed again, the same counts as at start.

### Open each tablet (5 min)

- [ ] Officer on duty: `/CrimsonPolice` -> the Officer UI opens on Home with your status, your next goal and a Find a
  mission button. **Esc** closes it and gives you full control back.
- [ ] Off duty: `/CrimsonPolice` -> "You need to be on duty to use Crimson-Police. Go on duty first.", no tablet.
- [ ] Supervisor: open the tablet, press **Supervisor** at the bottom of the sidebar -> the Supervisor UI opens on its
  first screen. A normal officer has no Supervisor button.
- [ ] Admin: `/CrimsonPoliceAdmin` -> the Admin UI opens on Home within a moment, with the setup checklist.
- [ ] A civilian types `/crimtab` -> nothing opens, as the criminal tablet ships off (it is in session 2).

### Guided tours (5 min)

- [ ] A character that never opened the tablet -> the Officer tour starts by itself; Next moves on, Escape ends it
  without closing the tablet; Done and reopen -> no tour. The **?** in the header replays it.
- [ ] The supervisor and the admin -> each gets his own tour (the Supervisor tour from My options -> Tours, the Admin
  tour on the first open of the Admin UI).
- [ ] The first real mission run of a new character -> tip cards at the top of the HUD (the HUD, the GPS line, the
  objectives, the result card), each closing by itself; you keep full control of the game.

### One mission of each block type (20 min)

Accept each from the Mission Board, or as the admin start it with `/CrimsonPoliceAdmin test <missionId>` to skip the
waiting. Each one should end on a result card, with its people, cars and markers gone afterwards.

- [ ] `beat_patrol` (checkpoint route) -> a yellow line to each numbered checkpoint, the HUD count goes up at each.
- [ ] `armored_truck_escort` (escort) -> the line goes to the truck, then to the destination flag once you are by it.
- [ ] `suspicious_activity` (field contact) -> the contact can be talked to, frisked and detained from the eye menu.
- [ ] `prison_break` (flee and arrest) -> orange inmate blips that run; each one you catch and cuff counts.
- [ ] `gang_shootout` (hostile waves, interact points, process scene) -> a red "Hostiles" circle, waves that fight
  back, then the scene to process.
- [ ] `business_check` (interact points) -> one door at a time with a steady line to the next.
- [ ] `hostage_rescue` (protect and rescue) -> blue blips on the hostages, a green "Safe point" flag once one is freed.
- [ ] `pursuit_sim` (pursuit) -> the driver flees; if he bails he is orange, red once he stops or gives up.
- [ ] `manhunt` (search area) -> a yellow search circle that shrinks after each clue.
- [ ] `bomb_disposal` (skill check) -> numbered device blips, the defuse skill check at each device.

### A unit run (5 min)

- [ ] Officer A invites officer B on the Unit screen -> B hears the invite tone and gets a toast; Accept -> both list
  two members.
- [ ] A accepts a Patrol mission -> both get the ready check; both press Ready -> the run starts for both, both see
  the same objectives, and both get a result card and a payout at the end.

### A supervisor action (5 min)

- [ ] The supervisor creates a Patrol call on Dispatch -> an officer of his department sees it and claims it; a second
  officer is refused; the run pays as a normal Patrol.
- [ ] Supervisor UI -> Department -> Officers -> an officer -> Commend, with a reason -> the commendation shows on
  his Profile's Recognition card.

### An admin settings change (5 min)

- [ ] Admin UI -> Money -> the gear -> change `Cash.dailyCap` and Save -> a toast; Settings -> History lists the
  change and the Activity log has it; no restart is needed.
- [ ] Put it back with Reset (or `CrimsonPoliceAdmin settings reset Cash.dailyCap` in the console) -> it shows the
  config.lua value again.

### A payout (included in the runs above)

- [ ] After a Beat Patrol played from the Mission Board -> the result card shows $250 (the Patrol payout), the bank
  gets it once, Admin UI -> Money -> Payments has one row for it. A test run started with the admin command does not
  pay.

### Restart mid-run (5 min)

- [ ] During a run, `restart Crimson-Police` in the console -> the HUD, markers and mission people go, the screen and
  the controls come back (nothing frozen), the run is dropped with no row, no pay and no cooldown. Settings changes
  and earlier payments are kept; the officer can accept a mission again at once.

### resmon (while you do the above)

- [ ] No run, tablet closed -> Crimson-Police on the client at 0.00 to 0.02 ms (0.00 to 0.01 ms with Debug off).
- [ ] During a run -> a steady low number, no spikes when the suspects or cars change owner between two officers.
  Write it down to compare after an update.

## Session 2: the risky changes, in this order

### 1. The 39 moved mission points

These points were moved a few metres to keep clear of other scripts' places (store registers and safes, the Fleeca
vault, the house-robbery entrance, a garage marker). Turn the mission's other locations off (guide 2.7), start it
there with `/CrimsonPoliceAdmin test <missionId> standard <location>` and walk to each point. The exact coordinates are
in the checklist section "Mission locations and other scripts".

- [ ] Bomb Disposal at the seven 24/7 Supermarkets (Innocence Boulevard, Clinton Avenue, Palomino Freeway, Senora
  Freeway, Mount Chiliad, Chumash with five points) -> every device sits inside on the floor, behind or in front of
  the counter or in the back room, never in a wall; the store's own robbery points still work.
- [ ] Hostage Rescue at the six Fleeca banks (Legion Square, Alta, Burton, Del Perro, Great Ocean Highway, Route 68) ->
  the two back-office robbers stand inside on the floor, not in a wall, clear of the vault door.
- [ ] Warrant Service, Wild Oats Drive -> the suspect waits on the step left of the door, not in the bushes, and
  surrenders onto the step.
- [ ] Stolen Vehicle Takedown, Route 68 east Harmony -> the car spawns on the Motor Hotel car park tarmac, clear of
  parked cars and the garage marker, and drives out onto Route 68.

### 2. The two mission desks

- [ ] Mission Row PD front counter, on duty -> "Open Crimson-Police" shows at the counter, not inside a wall; the
  qbx_policejob duty point and trash next to it still work. Off duty -> it hides within a second.
- [ ] Paleto Bay sheriff lobby (a new desk) -> "Open Crimson-Police" shows inside the lobby, not outside; the duty
  point still works.

### 3. Teams

- [ ] A unit of two: let the ready check run out -> "Not every unit member answered the ready check in time", no
  mission starts, and the leader sees the cancel at once.
- [ ] Settings -> Ready check and Cross-department operations on: a supervisor launches a Cross-Department Mission, a
  SAST and an FIB officer join, Start now -> both get the ready check; both Ready -> the run starts; invites from the
  operation card reach the other officer with a tone and a card; Leave asks to confirm.

### 4. The money engine

- [ ] A mission pay, a feature reward paid as an item (Settings -> Feature rewards, account `item`) and a manual pay
  of 100 (`Cash.allowManualCash` on, it asks for ENABLE) -> each is one row in Admin UI -> Money -> Payments; the
  mission and the manual pay arrive in the bank, the reward as the item.
- [ ] Pay an officer who is offline -> the row waits as Pending and is paid when he logs in, once.
- [ ] Turn `Cash.allowManualCash` off again (money tools ship off) -> the manual pay button is gone.

### 5. Real players (only if you will use them)

- [ ] With everything shipped off -> no `/crimtab`, `/crimsonheat` or `/surrender`, no Real players group in the Admin
  UI, and idle resmon as in session 1.
- [ ] Turned on (guide 6): a volunteer opens `/crimtab`, gets on the list, a unit takes an Investigation with a real
  suspect -> he sees the job, plays it, and History shows the result; a live crime from your crime script posts a
  LIVE call that a unit can claim and close. Follow the checklist section "Real suspects (ships off)" for the rest.

### 6. Your other scripts

With your normal scripts running (sc-dispatch, sc-ambulance, Renewed-Banking, sc-police, ox_inventory):

- [ ] Dispatch -> mark responding to a real dispatch call during a run: you are released from the run; switch
  character: the new one is not "On a call".
- [ ] Ambulance -> get downed during a run: the EMS script handles you, and the run goes on or ends as the HUD says.
- [ ] Banking -> a mission payout shows in the bank history.
- [ ] Police -> cuff and jail on a run work with your police script's own actions.
- [ ] Inventory -> with an inventory full to the weight limit, a mission that gives an item says "no room" and still
  starts.
- [ ] Then set one of them to `none` in Admin UI -> Settings -> Other scripts -> the console names it once, and a
  patrol and a unit mission still run and pay the same.
