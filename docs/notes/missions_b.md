# missions_b · built-in missions (Investigation + Tactical + Weekly Boss)

Files: `Crimson-Police/missions/builtin/{warrant_service,manhunt,gang_shootout,hostage_rescue,bomb_disposal,armored_truck_escort,prison_break,weekly_boss_kingpin}.lua`,
`tests/missions_b_spec.lua`. Each file has a header comment (what, where, which blocks) and exactly one
`RegisterMission({ ... })` in the Example-file field order. No payout field anywhere; `departments = {}`.

## Locations

| Mission | Locations | Per location |
|---|---|---|
| warrant_service | 6 houses: Grove Street (Davis), Forum Drive (Strawberry), Mirror Park, Wild Oats Drive (Vinewood Hills), Sandy Shores, Paleto Bay | door vec4, suspect vec4 (on the step beside the door), 4 fleeTo, 4 associates (front/side yard), yard (front yard) |
| manhunt | 5 regions: Sandy Shores, Grapeseed, Paleto Bay, Harmony, Grand Senora Desert (Yellow Jack Inn) | start = { coords = center, radius = 600 }, 6–7 clues (ground level), 7 hiding vec4 |
| gang_shootout | 5 hideouts: Stab City (Alamo Sea), Grand Senora scrapyard, Paleto Forest sawmill, Terminal container yard, Elysian Island docks | 14 spawns facing the approach, scene |
| hostage_rescue | 6 Fleeca banks: Legion Square, Hawick Ave (Alta), Hawick Ave (Burton), Blvd Del Perro, Great Ocean Hwy, Route 68 | 7 hostile spots, 3 hostages, safe marker outside |
| bomb_disposal | 6 24/7 stores: Innocence Blvd, Clinton Ave, Palomino Fwy, Senora Fwy, Great Ocean Hwy (Mt Chiliad), Barbareno Rd (Chumash) | 7 hiding spots at floor level (props stand on them) |
| armored_truck_escort | 3 routes: Blvd Del Perro → Hawick Ave (1.87 km, stop at Burton), Route 68 Harmony (0.87 km), Great Ocean Hwy Banham Canyon → Chumash (0.86 km) | route { points, stops }, 5–7 ambush points |
| prison_break | 6 breakout points outside the Bolingbroke perimeter (N, NE, E, W, NW, SW) | 8 inmate spawns, 2–3 escape routes |
| weekly_boss_kingpin | 3 compounds: La Fuente Blanca (Madrazo ranch), O'Neil Ranch (Grapeseed), Marlowe Vineyards (Tongva Hills) | 18 spawns, boss vec4, scene (all in front of the main house) |

How the points were placed: from well-known anchor coordinates (Fleeca teller/counter/vault positions,
24/7 clerk and back-room safe positions, shop and house entrance positions used by common FiveM
resources) plus offsets in each building's own frame. The anchors cross-check (every Fleeca vault sits
at the same offset from its teller, every 24/7 safe at the same offset from its clerk), so the interiors
are the most reliable data. Route waypoints on Boulevard Del Perro / Hawick Avenue and Route 68 follow the
road points in front of three and two Fleeca branches, which line up on one road. Rural spots (manhunt
regions, hideout spawn rings, compound spawns, prison surroundings) are estimates on flat, open ground;
their z is biased a little high so a ped drops rather than sinks. **Check in game with Admin test mode
before release**, in this order: the three truck routes (see below), the gang hideout spawn rings (the
Terminal and Elysian Island container yards first: a ring point can land inside a container), the three
Kingpin compounds, the prison breakout terrain heights, the manhunt spots.

The truck routes are not recorded road nodes: between the anchor points (the road in front of each
Fleeca, the Harmony 24/7 and a few Great Ocean Highway guesses) the waypoints are straight-line
interpolations every ≤ 140 m, with linearly interpolated z. That is right only where the road really is
straight between the anchors (Boulevard Del Perro, Hawick Avenue and Route 68 probably are; the Great
Ocean Highway north of the Banham Canyon Fleeca is not). The escort block passes a waypoint within 20 m
(2D), so a waypoint more than ~20 m off the road can stall the truck. Re-record the three routes with the
Mission Builder's route recorder (or check each waypoint with GetClosestVehicleNode) before release.

Placement rule used for peds and interaction points at buildings (after review): nothing is placed
behind a facade. Most base-game houses and ranch houses have no interior (or only locked story-mode
doors), so a point behind the front door is inside the building's collision: a ped spawned there is stuck
and an ox_target point there cannot be reached. Warrant Service associates and yard markers and every
Kingpin spawn and boss point therefore sit in front of the facade (towards the street / approach). The
Fleeca and 24/7 interiors are real, enterable interiors, so their inside points stay inside.

Guardrails the spec checks: counts, spacing (100 m), map bounds (x −4000..4600, y −4200..8000), every
vector outside every `Config.Builder.noBuildZones` circle (including the Crimson-Arena trailer park and
lobby) and every route / escape route / flee path segment clear of them, every placed point 30 m+ from its
start (except the manhunt centre and road routes), every point of a location within 150 m of its start
(except the manhunt circle, the road route and the prison escape routes, which have their own checks),
every z within 8 m of the start's z (25 m for routes and manhunt spots), hostile spawn headings facing the
approach (within 90°), door headings facing the street, flee paths and escape routes contiguous (no jump
over 250 m, starting at the house / breakout), prison points 180 m+ from the zone centre and 230 m+ from the
prison middle, road route length / a waypoint every 150 m / start–end, ambush spacing and distance to the
route, armed budget (Kingpin: 30 + boss = 31 ≤ 40, so no exception was needed). Escape routes also stay 150 m clear of
the Crimson-Arena Skydome (1500, 3000; z 1201) even though it is in the air and has no no-build zone.

## Contract interpretations

1. hostile_waves objectives leave `spawns` out, exactly like the spec's Example file (the block default
   is `'spawns'`). flee_arrest scatter mode writes `spawns = 'spawns'` (ARCHITECTURE 3.3 lists it there).
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
8. Warrant Service `suspect` is on the door step, 0.3 m out and 1.2 m beside the `door` point ("inside or at
   the door"): see the placement rule above and the flee_arrest mismatch below.

## Requests to other slices

- **modules/missions (engine_a)**: `normalize` calls the blocks' `validate(obj, d, loc)` before it sets
  `d.source`, so the blocks treat built-ins as custom (strict). `prison_break` (`s_m_y_prisoner_01`,
  `s_m_y_prismuscl_01`: prison clothes) and `weekly_boss_kingpin` (`g_m_m_armboss_01`) are then rejected by
  the Mission Builder's allowed-model list. Set `d.source = source` before the block guardrails run.
  The spec reports this (`LOADER:` lines) and checks that both pass with `source = 'builtin'`.
- **missions/builtin/index.lua** now exists and lists all 8 ids of this slice (resolved).
- **escort / search_area blocks** now exist; the Armored Truck Escort and Manhunt objectives pass their
  `defaults` + `validate` in both builtin and strict (custom) mode (resolved).
- Ids recorded by blocks that these files value: `hostage_hit` −50 each (protect_rescue), `inmate_alive`
  +10 each (flee_arrest aliveBonus), `devices_found_fast` +10 (interact_points fastBonus),
  `kingpin_alive` +50 (hostile_waves boss).
- **Locale**: labels in the files are plain English (`'Knock and announce'`, `'Cut restraints'`, …); the
  blocks show a locale key when one exists, else the text.

## Mismatches with blocks

- **flee_arrest, door mode** (`moveToDoor`): the block assumes the suspect waits *inside* and, on
  surrender, stands him 1 m past the door on the side away from where he waited. A suspect placed in front
  of the door would be moved *into* the house, and so would one placed exactly on the door point once
  collision nudges him outward (the Forum Drive knock point is on the door plane). The files put the
  suspect on the step 1.2 m *beside* the door (0.3 m out), so the surrender move is sideways along the
  facade and its inward part stays under 0.3 m. A "no interior" option in the block (surrender where he
  stands) would be cleaner.
- **flee_arrest / hostile_waves strict model lists**: both blocks apply `Config.Builder.allowed.peds` unless
  `mission.source == 'builtin'`; the loader passes the mission before setting `source` (request above).
  Not fixable in the mission files: the prison clothes and the Kingpin model are card requirements.
- **escort arrival**: waypoints count as passed within 20 m in 2D, but arrival at the destination uses a
  3D distance (`U.dist`, `arrival` 20 m). The destination z of the Great Ocean Highway route (20.7) is an
  estimate, so a wrong z would shrink the arrival circle there. Check it in game (or make the arrival test
  2D in the block).
