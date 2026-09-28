# Crimson-Police · coexistence with Crimson-Arena

Crimson-Arena (`Crimson-Arena`, a Qbox PvP arena) runs on the same server. It was analysed file by file
(its source is not part of this repo). These rules are **mandatory** for every Crimson-Police module;
they refine ARCHITECTURE §0.14. Crimson-Arena is never edited, called (no exports, no events) or read
(no stashes, no tables).

## What Crimson-Arena does that matters

- Writes `Player(src).state.crimsonArena = { active = true, matchId = '<id>' }` (replicated, **no
  `source` field**) when a fighter is placed in a match and, within 1 s, for every spectator. It
  **overwrites without reading** the old value, and on exit/abort it **sets the key to nil
  unconditionally** — including for lobby members it never flagged (admin stop/wipe, resource stop,
  countdown overrun).
- On placement it sends `hospital:client:Revive`, forces `isdead/inlaststand = false`, moves the player
  into routing bucket **4210+**, teleports them into the arena, and stashes + clears their whole
  inventory (ox_inventory stash `crimson_arena_<citizenid>`); on exit it clears the inventory again
  (keeping money) and hands the stash back. It removes items named `armour`, `bandage`, `ammo-*` from
  players it believes owe them.
- Lobby members carry **no flag and stay in bucket 0 until placed**, so they cannot be detected in advance.
- Cancels `explosionEvent`s inside a live Trailer Park match (sphere 135 m around 2344.43, 2565.06, 46.67)
  and pushes certain players out of its keep-out zones every 250 ms; match players reappear at the lobby
  return point (-282.01, -2030.46, 30.15).
- Calls `SetNuiFocus(false, false)` unconditionally when it places a player; disables all controls
  while spectating (key mappings still fire).
- Never reads the bag itself; its own exports read a private table.

## Rules for Crimson-Police

Definitions: a value is **foreign** when `type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'`.
`CP.Alerts.foreignFlag(src)` returns true for a foreign value. `CP.Alerts.inArena(src)` returns
`foreignFlag(src) or GetPlayerRoutingBucket(src) ~= 0`. Use `inArena` for every gate below.

1. **Foreign flag or other bucket mid-run → leave the run.** CP.Alerts registers
   `AddStateBagChangeHandler('crimsonArena', nil, h)` (server; `src = GetPlayerFromStateBagName(bagName)`;
   the handler only queues work with `SetTimeout(0, ...)`, never yields and never writes the bag inside
   itself), and the runs 1 s tick re-checks `CP.Alerts.inArena(src)` for every active participant
   (accepted or in progress, tests and operations included). When true: `CP.Runs.removeParticipant(run, src, 'quit')`
   with the notification `run.left_for_arena`, drop src from CP.Alerts' intent table **without touching the bag**,
   `CP.Route.stop`, cancel any pending CP.Downed pick-up/EMS request, host succession if needed.
2. **Our flag wiped by Crimson-Arena → re-assert it.** CP.Alerts keeps `wanted[src] = { runId, setAt }`
   (only `set` adds, `clear`/removeParticipant/resource stop remove). When the change handler or a 1 s
   reconcile sees the value is nil while `wanted[src]` exists (participant still active, or downed with
   keepFlag and a pick-up pending), re-write `{ active = true, source = 'crimson-police' }` on the next tick
   (at most once per 250 ms per src; log the first per src per run). Never re-write over a foreign value.
   `has(src)` = `wanted[src] ~= nil`. An incoming nil never means "our run ended".
3. **Downed pick-up/EMS re-checks.** Immediately before `client:pickup`, `CP.Ambulance.revive` and
   `client:requestEMS`, the server re-checks `CP.Qbx.isDowned(src)`, `not CP.Alerts.inArena(src)`; if any
   check fails, cancel that pick-up/EMS (the run result stays `downed`) and `CP.Alerts.clear(src)` (which
   leaves foreign values alone). `CP.Ambulance.revive` refuses and logs for an in-arena src. The downed poll
   skips in-arena srcs. Client `client:pickup` re-checks `LocalPlayer.state.crimsonArena` (abort if foreign)
   before waiting for the revive and before `SetEntityCoords`; on abort always `DoScreenFadeIn` and clear
   the overlay; detect "revived" by polling `not IsEntityDead(PlayerPedId())` and metadata isdead/inlaststand false.
   After a foreign value changes to nil, CP.Alerts records `foreignClearedAt[src] = os.time()`; CP.Downed
   delays `client:requestEMS` until 11 s after that (sc-ambulance drops EMS requests for 10 s after an arena exit).
4. **Mission items are tagged and removed by metadata.** Give every mission item with metadata
   `{ cpRun = run.id, cpItem = true }`. Remove by slot from the player's own inventory
   (`exports.ox_inventory:Search(src, 'slots', name, { cpRun = run.id })` then `RemoveItem(src, name, count, nil, slot)`),
   never by bare name. Keep an orphan list by citizenid for items not found; sweep orphans (items whose
   `metadata.cpItem` is true and whose `cpRun` is not an active run) on `QBCore:Server:PlayerLoaded`, 10 s
   after that player's value changes from foreign to nil, and every 60 s for listed citizenids. Never give
   items to an in-arena src. Never touch stashes named `crimson_arena_*`. Mission/Builder validation rejects
   item names `armour`, `bandage`, `ammo-*`, `WEAPON_*`/`weapon_*`.
5. **Gates.** `server:acceptType` (every member), `server:joinOperation`, `server:unitRespond` (accept),
   `server:testRespond` (accept), `CP.Testing.start` (admin and testers) refuse with `err.in_arena` when
   `CP.Alerts.inArena(src)`. The route arrival check also requires `not inArena(src)` before
   `markArrived` / `CP.Alerts.set`.
6. **Anti-cheat, route and telemetry ignore in-arena srcs.** `CP.AntiCheat.checkEvent`, `server:routeStatus`
   and `server:telemetry` return false (`err.in_arena`) with no flag, penalty, drift or speed sample for an
   in-arena src; the speed check discards the position pair across any tick where the src's bucket changed.
   A whole-run speed/teleport flag is never raised because of such a src.
7. **No-build zones.** `Config.Builder.noBuildZones` includes "Crimson-Arena Trailer Park"
   (2344.43, 2565.06, 46.67, r 160) and "Crimson-Arena lobby" (-282.01, -2030.46, 30.15, r 60); the mission
   loader and builder reject any point inside them. `CP.Draw.pickLocation`'s player clearance ignores
   in-arena players.
8. **Client UI.** The CP client registers
   `AddStateBagChangeHandler('crimsonArena', ('player:%d'):format(GetPlayerServerId(PlayerId())), h)`; on a
   foreign value: `CP.Tablet.close()` (delete prop, stop animation), `lib.cancelProgress()` if a CP progress
   bar runs, hide the CP HUD and overlays. The command, keybind, tablet item and `OpenTablet` refuse
   (toast `err.in_arena`) while the local value is foreign. Call `SetNuiFocus(false, false)` only when a CP
   UI is open — never unconditionally. The tablet prop is non-networked (`CreateObject(..., false, false, false)`).
9. **Alert backstop.** Capture src and `t = os.time()` at receipt; decide with `CP.Alerts.wanted[src]`
   (intent), not the live bag. Clear `playerdown_/playerdead_` ids for t-1, t, t+1 with `{ 'police', 'ambulance' }`
   and `shots_` ids within `backstopRadius` (server-side coords). Skip srcs whose value is foreign
   (Crimson-Arena handles them). Never `CancelEvent()` shared events.
10. **Global natives.** Never call `SetPlayerTeam`, `NetworkSetFriendlyFireOption` or `SetCanAttackFriendly`
    on any player or player ped; never set routing buckets (`SetPlayerRoutingBucket`, `SetEntityRoutingBucket`,
    `SetRoutingBucket*`).
11. **weaponDamageEvent.** CP.Npc's handler returns early when `WasEventCanceled()` is true. Crimson-Police
    never calls `CancelEvent` on `weaponDamageEvent`, `explosionEvent` or any sc-dispatch event.
12. **Outlines.** If `SetEntityDrawOutline` is used, call `SetEntityDrawOutlineColor(r, g, b, a)` and
    `SetEntityDrawOutlineShader(0)` right before every enable; never change the render technique.
13. **Teleports.** Test-run teleport controls, `CP.Runs.anchor` moves and every Builder move refuse with
    `err.in_arena` for an in-arena src; the client re-checks `LocalPlayer.state.crimsonArena` before `SetEntityCoords`.
14. **Names.** Crimson-Arena uses `crimson_arena:*` events, `/arenaleave`, `/arenaconsole`, `/arenaadmin`,
    ox_target `crimson_arena_lobby`, tables/stashes `crimson_arena_*`. Crimson-Police uses `crimson-police:*`,
    `/CrimsonPolice`, `/CrimsonPoliceAdmin`, `crimsonpolice_*` key mappings, `crimson-police:*` target names,
    `cp_*` tables. If Crimson-Police ever listens to `crimson_arena:dispatch:enter/exit`, use AddEventHandler only.
