# npc · notes (modules/npc: the NPC state machine, host AI helpers, "Cuff suspect")

Files: `Crimson-Police/modules/npc/server.lua`, `Crimson-Police/modules/npc/client.lua`,
`Crimson-Police/locales/parts/npc.json`, `tests/npc_spec.lua`, `tests/fixtures/npc/client_check.lua`
(the client half, run by the spec in its own Lua state). Each Lua file's header comment is the full API
reference. This slice writes no SQL.

## API (ARCHITECTURE §5.11)

Server: `CP.Npc.setState(run, netId, state, extra)`, `getState(netId)`, `isNeutralised(netId)`,
`rollSurrender(run, netId, chance)`, `enableCuff(run, netId, opts)`, `onDeath(fn)`, `onDamaged(fn)`.
Client: `CP.Npc.apply(entity, cfg)`, `task(entity, action, args)`, `nearestParticipant(coords)`.

Net / game events:

| Name | Side | What |
|---|---|---|
| `crimson-police:server:npcCuff` (runId, netId) | C → S (plain net event, 3 per 2 s) | the cuff progress bar finished |
| `weaponDamageEvent` (sender, data) | S (AddEventHandler) | shots at surrendered/cuffed/restrained peds, hostage damage |
| `playerDropped` | S | forget reach samples and shot windows of that player |
| `crimson-police:client:start` / `client:participants` / `client:hostChanged` / `client:runEnded` | C (listened to, sent by runs) | participant list, host changes, run end |
| state bag `cp` (all entities) | C | host re-tasking and cuff option labels |
| state bag `crimsonArena` (`player:<me>`) | C | cancels a running cuff when Crimson-Arena places the player |
| ox_target global ped options `crimson-police:cuff`, `crimson-police:cuff:<n>` | C | "Cuff suspect" (and other labels) |

Recorded ids: `shot_surrendered` (CP.Runs.penalize, personal). Block events delivered with
CP.Runs.dispatch(run, cp.obj, src, ev): `{ type = 'cuffed', netId }`, `{ type = 'shot', netId, src }`,
`{ type = 'damaged', netId, attacker }`.

## Contract interpretations

1. **Who fails the mission.** Killing a surrendered, cuffed, restrained or unarmed ped fails the run, but
   the decision stays with the owning block's `onEntityDead` (every block implements it, with a 3 s
   "shot already in flight" grace after a surrender). CP.Npc only attributes the killer and reports the
   death through `CP.Runs.entityDied`; it never calls `failRun` itself (that would bypass the grace).
2. **Death detection.** 1 s over every ped in `run.entities` of every live run (`kind == 'ped'`).
   `GetEntityHealth <= 0` is a death. An entity that no longer exists while its record is still in
   `run.entities` is a death at the first missed check (killer nil), which is before the engine's own
   2-check vanish rule, so the onDeath listeners hear about it too; a ped removed with
   `CP.Runs.deleteEntity` (record and entity together) is not a death. Exactly once: CP.Npc's own flag
   plus the engine's `entities[netId].dead`. The engine leaves ped health deaths to CP.Npc because
   `CP.Npc.onDeath` exists (modules/runs checks for it).
3. **Killer attribution.** `GetPedSourceOfDeath` → a player's own ped (matched against `GetPlayerPed` of
   every player) or the driver of the killing vehicle (`GetPedInVehicleSeat(veh, -1)`). An NPC source means
   "no player" (no fallback). No source at all → the last player weapon hit on that ped within 5 s. A killer
   who is in the arena (`CP.Alerts.inArena`) is dropped (nil).
4. **Participant** always means an ACTIVE participant (`run.participants[src].status == 'active'`), the
   same rule as `CP.Runs.isParticipant` and `CP.AntiCheat.onNpcKilled`. A player who left the run counts
   as outside help.
5. **setState(run, netId, state, extra).** The bag is replaced as a whole (`Entity(e).state:set('cp', bag, true)`).
   `extra.cfg` merges into `bag.cfg`; `extra.task = { action, args }` is a one-off host task
   (`CP.Npc.task`) for any state; other keys are copied; `run`, `obj`, `state`, `seq` are protected.
   A state change drops a previous `task`. `seq` increments on every write. The same state without
   extra is a no-op (no replication). Refused (false): unknown state, bad net id, ended run, a net id
   whose bag belongs to another run, a missing entity.
6. **rollSurrender** uses one deterministic stream per run, `CP.U.rng((seed ~ 0x4E504331) & 0x7FFFFFFF)`,
   and rolls each ped once: repeated calls return the first result (a client spamming 'low_health' cannot
   re-roll). `chance` is a fraction; a value above 1 is read as a percentage (builder units).
7. **enableCuff** stores `bag.cuff = { label, duration, maxDistance }`: label trimmed, at most 64
   characters, default `CP.L('npc.cuff')`; duration 500–60000 ms (default 5000); maxDistance 1–10 m
   (default 3.0). The option only shows while `state == 'surrendered'`.
8. **Cuff validation** (beyond the brief, all server-side): the run is In progress, the sender is an
   active and arrived participant, `CP.Access.getOfficer` passes, the sender is not in the arena, the net
   id is a live ped of this run whose bag says surrendered and cuffable, the sender is within
   `maxDistance + 0.5 m`, and the sender has been within `maxDistance + 1.5 m` for at least
   `duration − 2 s` (sampled every second by the watcher) so a modified client cannot skip the progress
   bar. Then `setState('cuffed')` first (blocks check `getState(netId) == 'cuffed'`), then the dispatch.
   A block refusing the event does not revert the state (blocks also pick cuffs up from the bag on tick).
   Every refusal sends the sender a toast `err.npc_*` through `CP.Tablet.notify`.
9. **shot_surrendered.** Counted once per shooter and ped per 2 s (a burst is one shot), never within 3 s
   of the surrender (a shot in flight), for any weapon except unarmed/melee/vehicle/fall hashes, and for
   `restrained` hostages too (as §5.11 lists). The shooter gets the warning toast `npc.shot_surrendered`
   with the value of `Config.Scoring.common.shotSurrendered`. Scoring maps the id to that value.
10. **The shooter of a weapon packet** is the entity named by `data.parentGlobalId` when it resolves: a
    player's ped or a vehicle a player drives → that player; an NPC (for example a hostile the sender owns)
    → nobody. Otherwise the sender. `hitGlobalIds` and the single `hitGlobalId` form are both read, at most
    32 hits. The handler returns at once when `WasEventCanceled()` and never cancels anything; in-arena
    senders are ignored (docs/CRIMSON_ARENA.md rules 6 and 11).
11. **The host-owned gap.** weaponDamageEvent is only raised for damage to an entity owned by ANOTHER
    client, and the run host usually owns every mission ped. A 1 s health + armour poll covers it: a drop
    with no weapon event in the last 2 s is attributed with `GetPedSourceOfDamage` (a player's own ped for
    shots; any source for hostage damage). A drop with no source is ignored, so a host lowering max health
    in `apply` never counts as damage.
12. **onDamaged** fires only for peds whose role is `hostage`, for every detected hit (attacker nil = an
    NPC). `{ type = 'damaged' }` is dispatched to the block only when the attacker is a participant. One
    report per ped and attacker per second.
13. **Client task speeds are m/s** (the pursuit and escort blocks send m/s); `kmh` is accepted instead.
    A numeric `drivingStyle` wins over the `style` name. Names: `careful`/`cautious` 786603 (stops for
    cars, peds and red lights), `normal` 786475, `fast` 786492 (all keep to their lanes), `reckless` 787004
    (may use oncoming lanes to overtake).
14. **Managed tasks.** The host's AI loop (500 ms, only while it manages a ped) retargets combat to the
    nearest active participant every 3 s (switching when another is 40% closer), steps flee and drive
    routes, re-issues tasks of stuck peds and keeps the kneel / cuffed poses playing. A managed task ends
    when the ped's cp state changes or it leaves the vehicle it was driving: whoever owns the new state
    re-tasks (pursuit's `TaskLeaveVehicle` after 'stopped' is never overridden). Repeated identical pose
    and combat tasks are ignored (no animation replay); identical movement tasks are only debounced for
    1.5 s, so a block re-tasking a stuck ped later is obeyed.
15. **Routes** start at `args.startIndex`, or at the nearest point ahead (the first local minimum of the
    distance along the route, 50 m hysteresis, so an out-and-back route passing the ped is not skipped).
    A waypoint is reached within `max(12 m, 1.2 × speed, stopRange + 4 m)` (2.5 m on foot) or when passed
    close by (within 3× that and beyond it along the next segment). A flee route ends in
    `TaskSmartFleePed` from the nearest participant; a loop wraps.
16. **"No ragdoll/flee when hostile"**: flee attributes off, combat attributes 17 off / 58 on,
    `SetPedCanRagdollFromPlayerImpact(false)` and blocking of non-temporary events. Ragdoll from weapons
    stays on because several blocks make suspects give up when stunned (a ped that cannot ragdoll cannot
    be tased). `SetPedDiesWhenInjured(true)`: no writhing ped that is neither dead nor neutralised.
17. **apply on a new host** never heals: health is set only on an untouched ped (health at max), armour
    only when it is 0 on an untouched, undamaged ped; max health and weapons are ensured every time.
    Calm states (surrendered, cuffed, restrained, freed, safe) are disarmed (RemoveAllPedWeapons, no
    drop) and in CRIMSONPOLICE_NEUTRAL; `cfg.group` ('hostile'|'neutral') picks the group otherwise.
18. **Relationship groups.** From CRIMSONPOLICE_HOSTILE: 5 (hate) to PLAYER as §6.1 says, 0 to itself,
    3 to CRIMSONPOLICE_NEUTRAL and to the common ambient/gang groups incl. sc-npcpolice's
    NPCCALL_HOSTILE / NPCCALL_RIVAL. From CRIMSONPOLICE_NEUTRAL: 3 to everything. PLAYER's own relations
    are never set. Because every player is in PLAYER, "hostile only to participants" is enforced by
    targeting (TaskCombatPed on participants only, blocked non-temporary events, the retarget loop);
    a non-participant who walks into the firefight can still draw fire.
19. **One option per label.** ox_target labels are static, so the global option set holds
    `crimson-police:cuff` (default label) and one `crimson-police:cuff:<n>` per other label a block passes
    to enableCuff (e.g. "Detain driver"), at most 8, added the first time a bag with that label is seen.
    canInteract: the ped's `cp.run` is the local player's run, `cp.state == 'surrendered'`, `cp.cuff` set
    with this label, within `cp.cuff.maxDistance`, on foot, alive, not in the arena, no cuff running. The
    progress bar is cancelled when the suspect stops being surrendered, moves out of reach + 1 m, or
    Crimson-Arena places the player; nothing is sent then.
20. **Host bookkeeping.** The `cp` handler waits one frame (change handlers run before the value is in
    the bag), applies cfg once per entity handle after `CP.Runs.control`, and re-tasks only on a state or
    task change. First sight of a ped (stream-in) or a host change uses the poses without transitions.
    On `client:hostChanged` to this client every known ped of the run is re-applied and re-tasked; the old
    host drops its AI loop.

## Requests to other modules

- **runs (server)**: keep removing the record in `deleteEntity` together with the entity (CP.Npc counts a
  still-listed missing ped as dead), keep `kind = 'ped'` on ped records and keep deferring ped health
  deaths while `CP.Npc.onDeath` exists. Nothing else needed.
- **runs (client)**: keep `CP.Runs.current().participants` as the list `{ src, status, ... }` and
  `isHost` current (CP.Npc also caches the client:start / client:participants lists).
- **scoring**: `shot_surrendered` arrives as a personal penalty, count 1 per incident (see 9); its label
  `penalty.shot_surrendered` is scoring's (not in npc.json, to avoid a duplicate key).
- **blocks (all)**: pass task speeds in m/s (or `kmh`); give fleeing peds their route in `cfg.fleePoints`
  (or setState extra `fleePoints`) so a new host keeps it; set `cfg.group`; when a block issues natives
  directly (TaskLeaveVehicle, TaskVehicleTempAction), move the ped to a new cp state as well so CP.Npc
  stops managing its previous task. `onDamaged` only reports hostages.
- **anticheat**: `onNpcKilled(run, killerSrc)` is called at most once per ped death, only for killers who
  are not active participants and not in the arena.
- **locale merge**: `npc.json` holds `npc.cuff`, `npc.shot_surrendered` and the `err.npc_*` keys.

## Tests

`lua5.4 tests/run.lua npc` → server spec (setState/getState/isNeutralised, rollSurrender determinism,
caching and distribution, enableCuff clamps, every cuff refusal and the rate limit, the dwell rule, the
death watcher incl. vehicle, NPC, fallback, arena, vanished, deleted and ended-run cases, weaponDamageEvent
incl. grace, bursts, melee, parent resolution, arena, hostages, the health poll, pruning, the locale part)
plus the client checks (relationship groups FROM our groups only, the ox_target option set, apply, every
task action, route stepping, stuck recovery, state-change and vehicle-exit handling, the bag handler on
and off the host, host change, canInteract, the cuff flow incl. cancel and arena placement, ox_target
restart, run end, resource stop).
