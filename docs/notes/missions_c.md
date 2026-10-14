# missions_c · block upgrades, five new missions, Mission Builder (WP3)

WP3 of the parity-plus build (design §7 WP3, §2.3–2.5, §2.13, §3.2, §4.2). English only. Item rewards stay off
by default, and no mission file has a reward or payout field. Every mission here works with the database on
and off. The new missions are built on WP2's `field_contact` and `process_scene` blocks and WP2's
`CP.Custody`.

## Block upgrades (all optional; an objective without them behaves exactly as before)

### pursuit (`blocks/pursuit/server.lua`, `client.lua`)

| Field | Meaning |
|---|---|
| `responses = { yield, flee, fight }` | Weights. Each vehicle rolls one from its own seed stream, so every participant and every re-run with the same seed sees the same result. `yield` pulls over with hazards and brakes. `flee` is the old pursuit. `fight` makes the occupants get out armed. |
| `handoff = 'contact'` | When the car is stopped, the pursuit writes `run.shared.contacts = { vehicle, occupants = {{netId, seat, state, truth}}, observed, forced, profileSet }` and calls `CP.Runs.adoptMany` so the next `field_contact` objective owns the car and its people. This happens before the pursuit completes. Occupants still seated count as settled. |
| `observe = { kind or kinds, zoneSpeed, over, behind, seconds, tolerance }` | The violator cruises past the officer. `pace`: the officer's samples are graded on their median, and it passes when the median is at least `zoneSpeed + over[1] - tolerance`. `zoneSpeed` is a number or a location key. `follow`: the officer stays within 60 m behind for 8 s. Both need the officer behind the violator. The snapshot's `watch = { behind, seconds }` gives the HUD that violator's own window. The violator gets its HUD cue and its blip only after it passes the observation point. |
| `stop_without_cause` | Lights before the observation completes cost the lighting officer −15. The penalty is personal (`{src}`). Everything else is graded normally. |
| `spawnOffset` | Spawns upstream along the route, capped at 250 m, so the car drives past the officer. |
| `driveBy` (percent), `ram` (percent) | Drive-by: a passenger targets the nearest participant within 40 m. Ram: a fight car that is boxed in rams once, and only a participant. |
| `profileSet` | Hidden truths for the occupants (`armedTruth` is server-only). The truth is armed only when the occupant fights. |
| `team = n` | The objective is skipped at start when fewer than `n` participants are in the run. Traffic Enforcement uses this for its second violator. |
| `'removed'` event | A car the engine removed is never stopped and never earns `vehicle_stopped_fast`. |
| Stats | `vehicles_stopped` (shared by the participants) and `noteArrest` on each cuff. |

### interact_points

| Field | Meaning |
|---|---|
| `together = { count, window, soloProgress }` | `min(count, active participants)` distinct officers, each within `window`. A hold that is too old, or a second hold by the same officer, resets with a HUD line. When the unit drops to one officer, held points finish and `soloProgress` applies. |
| `hidden.kind = 'seize'` | No prop and no `run.shared.devices`, so Bomb Disposal is unchanged. Each find notes the `evidence` stat. |
| `hidden.action = { label, duration }` | A follow-up seize at each find. The objective waits for every follow-up. |
| `finds = { chance, pool }` | Rolled once per point. A find notes `evidence`, is added to `run.shared.evidence` and shows a HUD line. |
| `fastBonus.after = n` | The fast bonus clock starts when objective `n` ends, not when this objective starts. Drug Lab Raid and Gang Hideout Raid use `after = 1`, so `stash_found_fast` counts from the breach. |
| ANIMS | Adds `notepad` (`CODE_HUMAN_MEDIC_TIME_OF_DEATH`) and `photo` (`WORLD_HUMAN_PAPARAZZI`). |

### skill_check

`onFail = 'fail'` is the default and keeps the old behaviour. The other form is
`onFail = { setback = { label, duration, penalty }, retryAfter }`: `failAfter` misses start a recovery step.
The recovery is a dwell at the target sampled by the dwell sampler, and a `'recover'` report finishes it. The
officer who missed pays `penalty`, and a retry opens `retryAfter` seconds after the recovery. The case never
fails. The state sends `setback` and `retryIn`.

### flee_arrest

| Field | Meaning |
|---|---|
| `demeanour` | A fixed value, weights, or `'rolled'`. The door response comes from `DOOR_RESPONSE`. A compliant or nervous inmate who scatters surrenders. |
| `feint` (percent) | Rolled at the first surrender, for unarmed suspects only. The suspect bolts after `Config.Npc.feintAfter` when nobody is within `feintRange` and nobody is aiming. The client reports aim. Killing a feinting suspect still fails. |
| `custody = 'handover'` | Calls `CP.Custody.enableChain`. The suspect counts as done only once handed over. |
| Stats | `noteArrest` on each cuff. |

### hostile_waves

| Field | Meaning |
|---|---|
| `behaviour` | Weights of hold, balanced and push, rolled per spawn from the objective's own seed. |
| `spawnSets = { keys, use, intel }` | Picks `use` location keys. The intel line `block.hostile_waves.intel` names the chosen sets and is stored in `run.shared.intel`. |
| NpcDifficulty feel | Changes `healthMult` and `surrenderMult` only. |
| Stats | `noteArrest` on each cuff. |

### protect_rescue

`CP.Runs.noteStat(run, nil, 'rescues', 1)` when a hostage reaches the safe marker.

## Missions (`missions/builtin/`, 19 in `index.lua`)

| Mission | Type, officers | Locations | Objectives |
|---|---|---|---|
| parking_patrol | patrol, 1, quietPatrol | 7 districts × 10 kerb spots | field_contact parked (`parking` truths) |
| suspicious_activity | investigation, 1–2 | 7 scenes: car, people, fleeTo, transport | field_contact scene |
| traffic_enforcement | patrol, 1–2 | 7 corridors, each with a `speed` key | pursuit observe + handoff; field_contact stop; the same pair again with `team = 2` |
| drug_lab_raid | tactical, 2–4 | 7 rural labs, 250 m clearance | breach together; waves (inside/yard sets); cooks (`cook_arrested`); stash seize (`stash_found_fast`); shut-down skill_check with a setback (`lab_fire`); process_scene |
| gang_hideout_raid | tactical, 2–4 | 7 hideouts | breach together; waves (front/house/garage sets) + lieutenant boss (`lieutenant_alive`); runners; cache seize; process_scene |

Every file has `vehiclePenalties` and a header that says where each spot is and why. Geometry came from the
GTA vehicle-node graph. Kerb spots follow the straightest non-freeway edge. A corridor with any node inside a
no-build zone was rejected, so Paleto was dropped and Route 68 Lago Zancudo and GOH Banham Canyon were added.
**Check in game with Admin test mode before release:** the kerb spot headings, the lab and hideout interiors,
and the traffic corridor speeds.

Retrofits:

- **stolen_vehicle_takedown:** responses 25/65/10, `handoff = 'contact'`, `profileSet = 'stolenCar'`,
  `driveBy = 50`, and a field_contact stop objective (stolen revealed, custody cuff). It also gets the
  `vehicle_impounded` bonus (`each`).
- **warrant_service:** yard `finds` at 60%, then process_scene (scene `yard`, no coroner, `minSeconds = 5`).
- **gang_shootout:** process_scene (4 bodies, no coroner).
- **beat_patrol, business_check:** already `quietPatrol = true` (WP1). No change.

## Zone lint (`tests/zone_lint_spec.lua`)

A footprint is a location's start plus every point in it. A route (`{ points }`) counts by its two ends only.
New missions must keep `Config.Draw.zoneClearance` (200 m) from every other mission's footprint, and
drug_lab_raid must keep 250 m. No point may be inside a no-build zone. The 102 existing close pairs are in
`tests/zone_lint_baseline.txt`. They produce one warning line and never fail the spec. A pair that is not in
the baseline fails. `BASELINE_MAX` stops the baseline from growing.

## Mission Builder

- **`modules/builder/server.lua`:** minimum seconds are field_contact 30 and process_scene 5. The builder
  handles percent, seconds and spawn fields for every option above, along with the Lua export's key order
  and its fraction and float keys. field_contact people and cars can be scaled.
- **`B.customBonusFields`:**
  - strips `allCorrect` and `aliveBonus` points from field_contact;
  - forces process_scene's `aliveBonus` to `{ id }`;
  - drops a skill_check setback `penalty` that is not in Config.Bonuses.
- **`builder:config`:** lists both new blocks with their ranges from `Config.Blocks`.
- **Client and web:**
  - kerb spots with a rule (`streets` from the client's place callback);
  - FieldContact and ProcessScene panels;
  - a parity panel for each upgraded block;
  - spawn-set keys and the armed count.

## Deviations and gaps

- **`vehicle_impounded`** (final review): field_contact records it, shared, for each car lawfully impounded
  (an Impound graded Best or Acceptable) when the mission's card lists it, so Stolen Vehicle Takedown pays its +10.
- **Not built, under the English-only decision:**
  - the CP.L → CP.Lt conversion of block HUD text;
  - the French and German HUD test;
  - builder dates through format.ts.
- **Timing:** the skill_check retry is timed from the end of the recovery.
- **Pace threshold:** it is `zoneSpeed + over[1] - tolerance`.

## Tests

- `tests/missions_c_spec.lua`:
  - loaders and cards;
  - end-to-end runs at every tier each mission supports, including a decision ledger with no wrong decision;
  - one violator solo and two with two officers;
  - the toxic-fire setback;
  - the Stolen Vehicle Takedown stop, the Warrant Service finds and the Gang Shootout bodies.
- `tests/zone_lint_spec.lua`.
- Additions to `blocks_a_spec`, `blocks_b_spec`, `blocks_c_spec`, `missions_a_spec`, `missions_b_spec` and
  `builder_server_spec`:
  - the new blocks in `builder:config`;
  - a field_contact and process_scene draft (guardrails, the armed budget, unit and Lua-export round trips);
  - reward-like fields are stripped;
  - a Builder duplicate of every new mission and every retrofit validates.
