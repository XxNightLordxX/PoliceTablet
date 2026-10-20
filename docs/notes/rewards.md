# Item rewards (WP7) · modules/rewards

Optional ox_inventory item rewards (SPEC "Item rewards (optional)"). Off by default: `Config.Rewards.enabled = false`
ships, and while it is off no listener writes a row and nothing calls ox_inventory. Only admins set rewards, in
config; mission files and the Mission Builder never carry a reward field (CP.Missions refuses reward-like keys).
WP9 copies the API rows below into docs/ARCHITECTURE.md.

## Data (cp_item_rewards, 006_item_rewards.sql, both storage modes)

One row per officer, source, source key and item (`uq_reward`). `row_id` is the cp_mission_runs row for run, medal
and boss rewards (so they are held and forfeited with it), NULL for goal, level and season rewards.

| source | source_key | when |
|---|---|---|
| run | run_uuid | row:settled: the run entry's rolls (one row per item, counts added) |
| medal | run_uuid | row:settled: Config.Rewards.medals[gold/silver/bronze] from row.medal |
| boss | `week:<CP.Schedule.weekKey()>` | row:settled of a Weekly Boss run (run.isBoss): weeklyBoss, once per week |
| goal | `<goalId>@<period>` | goal:completed: goals[goalId], else goals.daily / goals.weekly by the period prefix |
| level | the level number | xp:levelUp: levels[n] for every level passed, once per level |
| season | `champion:<id>` / `top10:<id>` | season:ended: season.champion for every officer of the champion department with a completed, unflagged, unvoided run row (not a manual award or goal row) in the season; season.top10 for the top 10 |

Status: `held` (flagged run, or a voided row's reward not given yet) → `pending` (waiting to be given: the Rewards
locker) → `giving` (claimed, AddItem running) → `given`; `forfeited` when the voided row's dispute window closes.
given and forfeited are final. A row left in `giving` (AddItem raised) is never retried automatically; it is listed
in Admin UI → Leaderboards → Item rewards → Stuck.

Every statement is inside the saves folder engine's constructs (INSERT IGNORE, COALESCE(SUM), GROUP BY,
SELECT DISTINCT, LIMIT ? OFFSET ?, FROM_UNIXTIME / UNIX_TIMESTAMP); times are written from os.time(), never NOW().

## Rules

- Who: each participant of a Completed, non-test run who met the presence share (p.flagged.reason 'presence', or
  CP.AntiCheat.presenceShare below Config.AntiCheat.presenceShare in a run of 2+). Flagged (participant or run):
  every reward of the row is `held`.
- Rolls: `U.rng(hash('<run id>:<citizenid>:item-rewards'))`, so a reconnect or a second settle rolls the same, and the
  unique key stores nothing twice. Each roll draws three numbers (hit, pick, count) whatever the outcome.
  Chance = entry.chance + tierChance[pay tier] + min(findBonus × the run's finds, findBonusMax), clamped to [0, 1].
  The run's finds are the `evidence` stats of every participant together (the bonus is the run's, so an officer
  who found nothing still gets it); at least row.evidence.
  The entry: byMission[mission id], else byType[type], else examplePools[type] when useExamplePools = true.
- Caps: per officer per reset day (CP.Schedule.dayStart), every source together, forfeited rows not counted:
  dailyItemCap items and dailyValueCap value (count × the item's configured value). A reward past a cap gives
  nothing (0 = no cap).
- Validation (3 s after start, on first use, and again once ox_inventory is up if it was not): a forbidden name (the loader's Crimson-Arena rules armour,
  bandage, ammo-\*, weapon_\*, plus money, black_money, cash, plus Config.Rewards.forbidden with `*` wildcards; all
  case-insensitive, anchored) or an item ox_inventory's Items() does not know is turned off, with a console warning
  (only when enabled, and for example pools only with useExamplePools) and a Config health line.
- Delivery (claim before give): `UPDATE ... SET status = 'giving' WHERE id = ? AND status = 'pending'`, then
  CanCarryItem, then `AddItem(src, item, count, { cpReward = <row id> })` (never cpItem, so the mission-item sweep
  leaves rewards alone). No room or a refused AddItem: back to pending (the locker) and one "no room" toast. In
  Crimson-Arena (CP.Alerts.inArena) or offline: no inventory call, the reward waits. Retried on officer:loaded and
  10 s after arena:exited. Never dropped in the world.
- row:approved: held → pending, then given. row:voided: pending → held. row:forfeited: held/pending → forfeited.
  CP.Cash fires row:forfeited only for a voided row whose cash was still held or pending, so the module runs its
  own job every 10 minutes (the cash job's rule): the held rewards of a voided row whose dispute window
  (Config.Disputes.windowHours from the row's created_at) closed with no open dispute are forfeited. This covers a
  row voided after its cash was paid, or one that carried no cash.
- History: every status change writes the row's rewards into the run's breakdown,
  `JSON_SET(breakdown, '$.items', ...)` on that path only: `breakdown.items` = `{ name, label, count, status }` with
  status given, pending, held or forfeited (giving shows as pending). The result screen's `result.items` leaves
  forfeited out. `RunItem.status` in web/src/types/run_ui.ts (not WP7's file) lacks 'forfeited'; the text
  `result.item_status.forfeited` is in locales/parts/rewards.json for the screen that renders the history items.

## API (server)

| Function | Meaning |
|---|---|
| `CP.Rewards.lockerCount(citizenid) -> n` | pending rows (30 s cache; home:extras reads the cache only: `extras.rewardsWaiting`) |
| `CP.Rewards.forRow(rowId) -> RewardRow[]` | the rewards of a cp_mission_runs row (history breakdown) |
| `CP.Rewards.deliver(citizenid) -> n` | give every pending row of an online officer (under the officer's lock) |
| `CP.Rewards.locker(src) -> RewardsLocker` | the Home locker: pending, held and giving rows; canClaim false with a reason key (rewards.reason.off, .arena, .inventory) |
| `CP.Rewards.claim(src, id) -> ok, data|errKey` | own row, pending, enabled, not in the arena, ox_inventory started, room |
| `CP.Rewards.adminView(page) -> AdminRewardsView` | pools with ok per item, this week's given/held/forfeited item counts, stuck rows, 25 rows per page, health |
| `CP.Rewards.validate()`, `forbidden(name)`, `health() -> { { level, text } }` | the item check and the Config health lines; registered with CP.ConfigHealth (`register('rewards', health)`) when that module exists |
| `CP.Rewards.entryFor(missionId, type)`, `chanceFor(entry, tier, evidence)`, `roll(runId, citizenid, entry, chance)` | pure roll helpers |

Listens to (CP.Hooks): row:settled (fills `result.items` with `{ name, label, count, status = given|pending|held }`),
row:approved, row:voided, row:forfeited, goal:completed, xp:levelUp (work in a thread: the hook may not yield),
season:ended, officer:loaded, arena:exited (SetTimeout 10 s), home:extras.

Net: callback `getRewardsLocker` → RewardsLocker; action `server:rewards:claim` `{ id }` (rate 2/s); callback
`admin:getRewards` `{ page }` → AdminRewardsView (openAdmin). Push topic `rewards` to the officer whenever their
locker changes.

## Web

- `web/src/types/rewards.ts`: RewardRow (citizenid and name on admin rows), RewardsLocker, RewardsHealthLine,
  AdminRewardsView (plus enabled, page, pageSize, health).
- `officer/components/RewardsLocker.tsx` (mounted on Home): hidden while empty; Claim per pending row, held rows show
  "Waiting for review"; refetches on the `rewards` push.
- `admin/components/ItemRewardsPanel.tsx`, shown by the Boards / Item rewards switch on Admin UI → Leaderboards.
- `mocks/rewards.mock.ts`: `?rewards=off` (the shipped default) and `?rewards=arena`.
- Texts: locales/parts/rewards.json (rewards.*, admin.rewards.*, err.reward_*).

## Tests

tests/rewards_spec.lua: off (no rows, no inventory calls, health line), validation (every forbidden pattern in any
case, a missing item, warnings, health entries, cpReward and never cpItem), rolls (determinism, tier and find bonus
with the cap, one row per item, a second settle, presence, test and failed runs), the status flow (held, approved,
pending, officer:loaded, voided, forfeited, claim before give, stuck), delivery (no room → locker → Claim, another
officer's row, Crimson-Arena and the 10 s retry, officer:loaded, home extras), example pools, caps across sources,
once-only goal, level, boss and season rewards, the admin view, and (review) CanCarryItem asked before AddItem, a
stale snapshot given nothing, a raising AddItem left giving, the run's finds for every participant, the forfeiture
job (paid cash, open dispute, dispute window), the history breakdown, champion rows without manual awards, and the
check re-run when ox_inventory starts late.
