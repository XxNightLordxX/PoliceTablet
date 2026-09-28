# missions_b · built-in missions (Investigation + Tactical + Weekly Boss)

Files: `Crimson-Police/missions/builtin/{warrant_service,manhunt,gang_shootout,hostage_rescue,bomb_disposal,armored_truck_escort,prison_break,weekly_boss_kingpin}.lua`,
`tests/missions_b_spec.lua`. Each file has a header comment (what, where, which blocks) and exactly one
`RegisterMission({ ... })` in the Example-file field order. No payout field anywhere; `departments = {}`.

## Locations

| Mission | Locations | Per location |
|---|---|---|
| warrant_service | 6 houses: Grove Street (Davis), Forum Drive (Strawberry), Mirror Park, Wild Oats Drive (Vinewood Hills), Sandy Shores, Paleto Bay | door vec4, suspect vec4 (inside the door), 4 fleeTo, 4 associates, yard |
| manhunt | 5 regions: Sandy Shores, Grapeseed, Paleto Bay, Harmony, Grand Senora Desert (Yellow Jack Inn) | start = { coords = center, radius = 600 }, 6–7 clues (ground level), 7 hiding vec4 |
| gang_shootout | 5 hideouts: Stab City (Alamo Sea), Grand Senora scrapyard, Paleto Forest sawmill, Terminal container yard, Elysian Island docks | 14 spawns facing the approach, scene |
| hostage_rescue | 6 Fleeca banks: Legion Square, Hawick Ave (Alta), Hawick Ave (Burton), Blvd Del Perro, Great Ocean Hwy, Route 68 | 7 hostile spots, 3 hostages, safe marker outside |
| bomb_disposal | 6 24/7 stores: Innocence Blvd, Clinton Ave, Palomino Fwy, Senora Fwy, Great Ocean Hwy (Mt Chiliad), Barbareno Rd (Chumash) | 7 hiding spots at floor level (props stand on them) |
| armored_truck_escort | 3 routes: Blvd Del Perro → Hawick Ave (1.87 km, stop at Burton), Route 68 Harmony (0.87 km), Great Ocean Hwy Banham Canyon → Chumash (0.86 km) | route { points, stops }, 5–7 ambush points |
| prison_break | 6 breakout points outside the Bolingbroke perimeter (N, NE, E, W, NW, SW) | 8 inmate spawns, 2–3 escape routes |
| weekly_boss_kingpin | 3 compounds: La Fuente Blanca (Madrazo ranch), O'Neil Ranch (Grapeseed), Marlowe Vineyards (Tongva Hills) | 18 spawns, boss vec4, scene |

How the points were placed: from well-known anchor coordinates (Fleeca teller/counter/vault positions,
24/7 clerk and back-room safe positions, shop and house entrance positions used by common FiveM
resources) plus offsets in each building's own frame. The anchors cross-check (every Fleeca vault sits
at the same offset from its teller, every 24/7 safe at the same offset from its clerk), so the interiors
are the most reliable data. Route waypoints on Boulevard Del Perro / Hawick Avenue and Route 68 follow the
road points in front of three and two Fleeca branches, which line up on one road. Rural spots (manhunt
regions, hideout spawn rings, compound spawns, prison surroundings) are estimates on flat, open ground;
their z is biased a little high so a ped drops rather than sinks. **Check in game with Admin test mode
before release**, in this order: Great Ocean Hwy route, the three Kingpin compounds, the Paleto sawmill and
Stab City spawns, the prison breakout terrain heights, the manhunt spots.

Guardrails the spec checks: counts, spacing (100 m), every vector outside every
`Config.Builder.noBuildZones` circle (including the Crimson-Arena trailer park and lobby), every placed
point 30 m+ from its start (except the manhunt centre and road routes), prison points 180 m+ from the
zone centre and 230 m+ from the prison middle, route length / gaps / start–end, ambush spacing, armed
budget (Kingpin: 30 + boss = 31 ≤ 40, so no exception was needed). Escape routes also stay 150 m clear of
the Crimson-Arena Skydome (1500, 3000; z 1201) even though it is in the air and has no no-build zone.

## Contract interpretations

1. `spawns = 'spawns'` is written explicitly in every hostile_waves objective (the block default).
2. Door-mode `knock.duration = 3000` (the card gives no knock time; the flee_arrest default).
3. Kingpin `cooldown = 1200` (the card has none). The weekly limit is `CP.Events.bossAvailable`; a
   one-week cooldown would block the next weekend.
4. Boss surrender `{ belowHealth = 0.25, chance = 0.30 }` (the hostile default) so "Kingpin arrested alive"
   can happen. `kingpin_alive` comes from hostile_waves' `boss.aliveBonus` default; the file does not set it.
5. Bomb device prop `prop_c4_final_green` (a common base-game C4 model); the interact_points default is
   `prop_ld_bomb`. Manhunt clue props: `prop_cs_heist_bag_02`, `prop_npc_phone_02`, `'witness'`.
6. minSeconds: hostage hostiles 30, Kingpin waves 90, bomb search 3, defuse 5, escort 45 (the shortest route
   takes about 52 s at 60 km/h), others at the block default or the card's progress time.
7. Scaling: escort waves and cars carry `max = 5` (the builder range); every other path is a plain string.

## Requests to other slices

- **modules/missions (engine_a)**: `normalize` calls the blocks' `validate(obj, d, loc)` before it sets
  `d.source`, so the blocks treat built-ins as custom (strict). `prison_break` (`s_m_y_prisoner_01`,
  `s_m_y_prismuscl_01`: prison clothes) and `weekly_boss_kingpin` (`g_m_m_armboss_01`) are then rejected by
  the Mission Builder's allowed-model list. Set `d.source = source` before the block guardrails run.
  The spec reports this (`LOADER:` lines) and checks that both pass with `source = 'builtin'`.
- **missions/builtin/index.lua** (not in this slice) must list the 8 ids above; it does not exist yet.
- **escort / search_area blocks** (not written yet): the files use exactly the ARCHITECTURE 3.3 fields.
  escort: `route = 'route'` (location `{ points, stops = { { at, wait } } }`, last point = destination,
  `start.coords` = first point = depot), `ambushPoints = 'ambushPoints'` (vec3 on the route, 150 m+ apart),
  `ambush = { waves, carsPerWave, perCar, models, weapons, accuracy, armour }`. search_area:
  `center` (= start.coords), `clues` (vec3 at ground level), `hiding` (vec4), `clueProps` (3 entries,
  `'witness'` = NPC). Ids to record: `truck_healthy`, `clues_first` (both in Config.Bonuses).
- Ids recorded by blocks that these files value: `hostage_hit` −50 each (protect_rescue), `inmate_alive`
  +10 each (flee_arrest aliveBonus), `devices_found_fast` +10 (interact_points fastBonus),
  `kingpin_alive` +50 (hostile_waves boss).
- **Locale**: labels in the files are plain English (`'Knock and announce'`, `'Cut restraints'`, …); the
  blocks show a locale key when one exists, else the text.
