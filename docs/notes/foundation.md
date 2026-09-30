# Foundation (WP1) · the engine contracts of the parity-plus build

What WP1 added for every later package: migrations 003–006, CP.Hooks, CP.Lt tokens, the engine's stats, decisions,
adoption, hidden spawns, reserved plates, held bodies and removed vehicles, the XP curve, mission tweaks, NPC
difficulty and the new Session fields. WP9 copies the API rows below into docs/ARCHITECTURE.md.

English is the only language in this build: CP.Lt tokens resolve in the server language, and no per-player language
exists (no column, pref, language list or picker; the final review removed the inert language field).

## Data (sql/migrations, both storage modes)

| File | Adds |
|---|---|
| 003_run_stats.sql | cp_mission_runs and cp_mission_runs_archive (same order, for the retention job's `INSERT ... SELECT *`): location_index, arrests, citations, impounds, rescues, vehicles_stopped, evidence, decisions_ok, decisions_bad, decisions_best, lethal, medal, mission_call_id, response_s; indexes idx_location and idx_call |
| 004_profile.sql | cp_officers: bio, avatar_kind, avatar_value, avatar_pending, avatar_status, avatar_reviewed_by, appearance, accent, ui_scale, profile_updated_at, calls_muted, bio_pending; tables cp_profile_reports and cp_commendations |
| 005_mission_calls.sql | cp_mission_calls |
| 006_item_rewards.sql | cp_item_rewards (unique key uq_reward) |

Every stat column is written on every row; only `state = 'completed'` rows are summed (badges, stat goals). The row
gets location_index, the stats, medal (1 gold, 2 silver, 3 bronze from the medal_* awards), mission_call_id and
response_s (seconds from accept to that participant's arrival).

## CP.Hooks (shared/init.lua, both sides)

`CP.Hooks.on(name, fn) -> id`, `CP.Hooks.off(id) -> bool`, `CP.Hooks.fire(name, ...) -> listeners that ran`. Every
listener runs in the caller's thread, in the order added, each in pcall (a failure is logged with CP.err).

| Hook | Arguments | Fired by | May yield |
|---|---|---|---|
| run:created | run | CP.Runs.create | no |
| run:arrived | run, src, isFirst | CP.Runs.markArrived (after the run moved to In progress on the first arrival) | no |
| run:inProgress | run | the engine, after every block's prepare | no |
| participant:left | run, src, endReason | CP.Runs.removeParticipant | no |
| row:settled | run, p, rowId, row, result | Settle, after the cash, XP and goals and before client:runEnded; listeners may add to result (items) | yes |
| run:ended | run, state, endReason | after every row (endRun, or the last participant leaving) | yes |
| row:approved / row:voided | rowId | CP.Scoring.onRowApproved / onRowVoided | yes |
| row:forfeited | rowId | CP.Cash.forfeit and the forfeiture job (now one UPDATE per row) | yes |
| arena:exited | src | CP.Alerts' 1 s reconcile, when CP.Alerts.inArena(src) turns false (flag or bucket) | no |
| xp:levelUp | citizenid, src or nil, oldLevel, newLevel | CP.Scoring's XP update | no |
| goal:completed | citizenid, goalId, period (`'daily:<day key>'` or `'weekly:<week key>'`, unique per period) | CP.Goals, after the goal row | yes |
| season:ended | seasonId, { champion, top10 = { citizenid } } | CP.Challenge, after the season results | yes |
| home:extras | citizenid, src, extras | CP.Scoring homeData (Home: `extras` in HomeData) | no |
| officer:loaded | src | CP.Cash's player-loaded path, right after the pending payments | yes |

## CP.Runs additions

| Function | Meaning |
|---|---|
| `noteStat(run, src|nil, key, n)` | citations, impounds, rescues, vehicles_stopped, evidence, decisions_ok, decisions_best, decisions_bad, lethal; nil src = every active participant now |
| `noteArrest(run, src, netId) -> bool` | one arrest per person per run; false for a repeat |
| `decide(run, src, entry) -> bool` | entry = { contact, kind, choice, verdict, bonusId, points, truthKey, bestChoice, facts, discoverable, knownAt, failKey, netId }; ledger, decision stats, noteArrest for an Arrest graded best/ok, personal award/penalty (points = 0: graded, no points), 'critical' fails the run with failKey |
| `adopt(run, netId, toIndex)`, `adoptMany(run, netIds, toIndex) -> n` | moves an entity to another objective (entity record, bag, CP.Npc.adopt) and sends the host `client:objective` `{ action = 'adopt', op = 'adopt', netId, obj, from }` |
| `ownerOf(run, netId)`, `entityEvent(run, netId, ev)` | the owning objective; dispatch an entity event (handed_over, impounded, removed) to it |
| `spawnPed(run, { hidden = true, armed, weapon, accuracy, armour })` | a contact: bag armed = false and no weapon/accuracy/armour; `armedTruth` counts toward the caps |
| `arm(run, netId) -> bool` | the draw: weapon, armour and combat cfg, once |
| `isMissionPlate(plate)` | every spawned vehicle gets a Config.Custody.plates plate, rerolled (5 tries) when CP.Qbx.plateOwned says a player owns it; a plate a mission asks for is kept only in that pattern and when no player owns it; plates come from their own random stream, never from the run seed (clients see plates) |
| `holdBodies(run, { roles, max })`, `heldBodies(run)`, `releaseBody(run, netId)` | bodies kept for Process the scene (FIFO past max); deleted at the run end |
| `pauseFastClock(run)` | stops the fast-completion clock; the time limit grows by 60 s + 20 s per held body; once |
| `noteExternalRemoval(netId, src, via, dist)` | remembered 15 s. A vanished run vehicle whose last server sample had engine and body above 0 is removed, not wrecked: `{ type = 'removed', netId, src, via }` to its objective; a participant's removal flags sc_impound and fails the run (reason.vehicle_removed); anyone else's, or none recorded (via 'unknown'), removes everyone with end reason vehicle_removed_external (abandoned: no points, cash or cooldown) and writes the audit (vehicleRemoved) |
| `completionsToday(citizenid, missionType|nil)` | completed rows since CP.Schedule.dayStart, no manual_award/goal/operation rows; 10 s cache cleared on a completion |
| create opts.missionCall | `{ id, code, area, targetS, staff }`: rapid_response is awarded (personal) on arrival within targetS unless staff |
| quietPatrol | mission definition flag (Beat Patrol, Business Check): lights_siren counts only once the run is in progress; the three LIGHTS_MISSIONS lists are gone |
| hud / hudFor / ctx.hud / ctx.send | CP.Lt texts are sent as tokens; the view resolves them (server language) |
| RunResult | adds decisions, stats (lethal left out), missionCall, progress (CP.Scoring's row:settled listener), items = {} |
| view | adds intel (run.shared.intel), missionCall `{ code, targetS, arrivedS }`, contact (CP.Custody.view when it exists) |

Client (modules/runs/client.lua): HUD patches and objective updates are resolved with CP.Locale.resolveAll before the
NUI; the 'adopt' action calls the new objective's client half `adopt(ctx, netId, from)` and the old one's
`release(ctx, netId)`; `CP.Runs.adoptedBy(netId)`.

## Other modules

- shared/locale.lua: `CP.Lt(key, vars)`, `CP.Locale.isToken`, `encode`, `tokenize(payload)`, `resolve(text, code)`,
  `resolveAll(payload, code)`, `label(key, fallback, vars)`. CP.L is unchanged.
- CP.Scoring: `levelXp(n)`, `levelOf(xp)`, `xpLevel(xp) -> { n, label, badge, xp, levelXp, nextLevelXp, prestige,
  next }` (xp = levelXp for old callers), `progressFor(citizenid, gained, pending)` (pending XP never sets levelUp), badges by_the_book and
  first_responder, engineOnly ids valued from Config.Bonuses (rapid_response from Config.MissionCalls.rapidResponse),
  one level-up toast (scoring.level_up with "Lv n" or "Lv n · band").
- CP.Missions: normalize keeps quietPatrol and decisions, refuses engineOnly ids and reward-like keys; Config.MissionTweaks
  (cooldown, timeLimit, startTimeout, disabledLocations, peds, vehicles, weapons) re-validated; `label(def, field, n)`.
- CP.Scaling: combat() adds Config.NpcDifficulty accuracyAdd/armourAdd; `feel()`.
- CP.Admin: `registerSubcommand(name, fn(src, args) -> ok, key, vars, helpKey)`.
- CP.Qbx: `plateOwned(plate) -> bool|nil` (read-only, the real oxmysql).
- CP.Npc: `adopt(netId, obj)`.
- CP.Goals: stat goals (`stat = 'arrests'` …) sum that column over completed rows; missionCall goals count rows with a
  mission_call_id. (Bounties most_arrests and most_calls still count completed runs until WP6.)
- CP.Tablet getSession: officer.avatar, officer.level, prefs, access { via, desk }, config.dispatch,
  leaderboardMetrics, profile, commendationKinds, rewards, format.

## Web

Types: shared/types.ts (LevelInfo, Avatar, Prefs, Session additions, RunResult sections, NavCounts, ConfigHealthItem),
types/run_ui.ts (DecisionEntry, RunProgress, RunStats, RunMissionCall, RunItem, view extras), types/custody.ts,
missioncalls.ts, profile.ts, rewards.ts. Screens: 'dispatch' after 'board' (placeholder). Components: Avatar
(initials in the frame colour), RewardsLocker and ReadyCheckBanner (render null), icons bell, truck, camera, gavel,
gift, idCard. format.ts: fmtDate and fmtDateTime (the locale's _meta.date_locale, en-GB). ResultScreen: level bar and
level-up, XP pending, mission call line, decision ledger and items, each only when present; `?result=parity` shows
them in browser mode.

## Tests

tests/foundation_spec.lua; the harness reads the migration list from FILES (H.migrationFiles, H.migrationVersion),
models entities (H.entity with velocity and a timeline over H.advance), and offers H.mockInventory, H.mockTarget,
H.plateOwnedStub and H.resetHooks.
