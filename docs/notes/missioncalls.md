# Mission calls and draw (WP4) · Dispatch, areas, claims, zone clearance and the daily cap

What WP4 built: the tablet's own call board (modules/missioncalls), the draw's area filter, footprints, zone
clearance, location memory, freshness and daily cap (modules/draw), the read-only SC-Dispatch summaries
(modules/integrations/sc_dispatch) and the Dispatch screen with the staff panel. WP9 copies the API rows below into
docs/ARCHITECTURE.md. English only in this build: every text is a key in locales/parts/missioncalls.json.

## CP.MissionCalls (modules/missioncalls/server.lua)

| Function | Meaning |
|---|---|
| `list(src) -> DispatchView` | The Dispatch screen; built only for officers with the tablet open (the getMissionCalls callback and the `calls` push to watchers) |
| `eligibility(src) -> { at, unit, types }` | The cached per-type state of src's unit: every accept check (CP.Draw.check), the eligible pool after the no-repeat rule, its missions and locations per area, the card's cash and points. Reused for Config.MissionCalls.eligibilityCache seconds; cleared on row:settled, participant:left and duty changes. The no-repeat history and the hourly and daily counts are read once per officer and kept until that officer's next settled row or duty change (a count at its cap is read again every 60 s, so the lock lifts when the hour or day passes); a claim reads them fresh |
| `areaFor(src, call) -> areaKey or nil` | The area a call names to that viewer: only with minMissionsPerArea missions and minLocationsPerArea locations in their eligible pool there; nil = county-wide (the board's pool, locations weighted towards the unit) |
| `claim(src, callId) -> ok, { runId } / { pending } / errKey` | Every accept check, then the call's rules (excluded units, the issuer's unit, paged, priority window, a pool); the claim window ranks by distance to the area centre, fewer calls won in the last hour, earliest claim |
| `withdraw(src, id, reason)`, `page(src, typeKey, area, leaderSrc)`, `create(src, typeKey, area)` | Staff calls, audited (category operations). A paged call toasts only the paged unit; when pageTime ends, the other idle units that could claim it get the toast once |
| `claimableCount(src) -> n` | Calls the viewer's unit could claim now (Home extras callsOpen, the board's callsOpen) |
| `areaOf(coords) -> key`, `areaIndex() -> { [type] = { [area] = { missions, locations } } }` | Areas (nearest centre) and the coverage matrix |
| `stats(citizenid) -> { answered, avgResponse, rapid }` | Completed claimed runs, average response_s and rapid responses |
| `supView(src) -> SupCallsView` | Open calls, today's calls (claimed calls of other departments hidden from supervisors), pageable idle units |

Hooks listened to: run:arrived (the call's run reached the start), run:ended (close with the outcome, or re-dispatch
once when nobody arrived and the end reason is quit, off_route, start_timeout, idle, real_call or force_recall),
row:settled and participant:left (cache), home:extras (callsOpen). CP.Schedule.onDaily deletes history older than
Config.Retention.missionCallDays. `/CrimsonPoliceAdmin missioncall <type> [area]` goes through
CP.Admin.registerSubcommand.

Rules worth knowing:

- A call's row moves open → claimed with `UPDATE ... WHERE id = ? AND status = 'open'` before the accept (claim
  before act); a declined ready check puts it back (`... AND status = 'claimed'`) with the offer time it had left.
- A declining unit, and the members of a re-dispatched claim, are excluded from that call by citizenid.
- Staff calls (paged or created) are `missionCall.staff = true`: CP.Runs never awards rapid_response for them. The
  issuer's citizenid is checked against every member of a claiming unit for the whole offer.
- The toast (`client:missionCall`) goes only to members of idle units who could claim it and have not set
  cp_officers.calls_muted (read at most every 30 s per officer); the client drops it on a run or in the arena.
  Saving the mute flag is the profile module's `server:profile:set` (WP6).
- Nothing is sent to SC-Dispatch: no export, no event, no unit status.

Net: callback `getMissionCalls`, `sup:getMissionCalls`, `admin:getAreaCoverage`; actions `server:claimMissionCall`,
`server:sup:mcWithdraw|mcPage|mcCreate` and `server:admin:*` (admins only); plain `server:mcWatch` (false = the
tablet closed, sent by modules/missioncalls/client.lua); push topic `calls` (DispatchView).

## CP.Draw additions (modules/draw/server.lua)

| Function | Meaning |
|---|---|
| `pool(type, members, opts)`, `draw(type, members, opts)`, `pickLocation(def, srcs, rng, opts)` | opts.area (hard: only missions and locations in that area), opts.avoid (soft), opts.nearCoords (county-wide weighting 1 / (1 + km / countyWeightKm)), opts.exclude (hard, as before) |
| `footprint(def, index) -> { vec3 }` | The start and every point of a location; route points (any list under a key named route) sampled every 50 m |
| `check(src, typeKey, counts?) -> ok, errKey` | Every accept check without changing anything (the claim runs exactly these); counts `{ lastHour(cid), today(cid, type) }` replaces CP.Runs' counts (the calls' cache) |
| `accept(src, typeKey, opts)` | The accept: opts.area, opts.nearCoords, opts.missionCall (`{ id, code, area, staff }`; the response target is set here from the unit's nearest member to the drawn start), opts.onDone (only when a ready check made it wait). Units of 2+ go through `CP.Units.readyCheck(unit, typeKey, onReady, onCancel)` when it exists (guarded fallback: the draw follows at once) and the accept returns `{ pending = true }` |
| `noRepeat(list, hist)`, `history(citizenid, type)` | The no-repeat rule on its own (for the eligibility cache) |
| `typeValues(type, officers, list) -> cash, points` | A card's numbers for the call cards |
| `recordLocation(citizenid, missionId, index)`, `locationStats(missionId)` | The in-memory location memory bridge; callback `admin:getLocationStats` |

Draw rules, in the order pickLocation applies them: reservations and opts.exclude and opts.area (hard); zone
clearance (Config.Draw.zoneClearance from every point of every held location of any mission, soft: falls back to
the reservation rule when nothing else is free); opts.avoid, which draw fills with each participant's last
Config.Draw.avoidLastLocations locations of that mission (cp_mission_runs.location_index plus the in-memory bridge,
soft); player clearance (as before); then a weighted pick: half weight for a spot any run took within
Config.Draw.locationFreshness, and the county-wide distance weighting. With equal weights the pick is the old uniform
one.

Daily cap: Config.Limits.maxCompletionsDay and Config.MissionTypes[type].dailyLimit through
CP.Runs.completionsToday; the accept refuses err.daily_cap, err.member_daily_cap, err.type_daily_cap or
err.member_type_daily_cap, and the board card is locked (`locked.daily = true`, `until` = the next day start).
BoardData gains `callsOpen`.

## CP.Dispatch additions (modules/integrations/sc_dispatch/server.lua)

- `realCallSummary() -> { total, p1 } | nil`: `SELECT priority, COUNT(*) FROM mdt_dispatch WHERE active = 1 AND
  (unique_id IS NULL OR unique_id NOT LIKE ?) GROUP BY priority` with Config.Calls.npcCallPrefix escaped and `%`
  appended (the saves folder engine has no LEFT(); both modes send it to the real oxmysql), cached
  Config.MissionCalls.realCallCache seconds, nil on error (the strip is hidden).
- `mdtCommendations(citizenid) -> list | nil`: employee_incidents, read-only, nil on error.

## Web

Officer Dispatch screen (filters All, Claimable, Near me; the real-call strip; notices; call cards with status,
offer countdown, crew, pay and rapid response; the claim confirm; Recent calls; the mute toggle), the Mission Board's
"n mission calls open" link and daily-limit badge, MissionCallsPanel (Supervisor Live Missions and the Admin Missions
Dispatch tab), AreaCoverageMatrix (Admin Testing) and LocationPlays (Admin Missions). Browser mock:
mocks/missioncalls.mock.ts (`?calls=empty|run|op`).

## Tests

tests/missioncalls_spec.lua (posting, areas and the pool property, refusals, the claim window, the priority window,
the ready check, lapses, Recent, withdraw, titles, staff calls, re-dispatch, mute, watchers, cache cost and the
0.25 ms budget, never SC-Dispatch, realCallSummary, stats, Home extras) and tests/draw_zones_spec.lua (areas,
footprints, zone clearance, location memory, freshness, county-wide weighting, the daily cap, the ready-check call
site, admin:getLocationStats). Both run in the three storage modes.
