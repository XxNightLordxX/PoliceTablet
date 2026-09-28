# Core slice notes (integrations, access, permissions, tablet)

Files: `modules/integrations/{qbx,sc_dispatch,sc_ambulance,renewed_banking}/`, `modules/access/`,
`modules/permissions/`, `modules/tablet/`, `locales/parts/core.json`, `tests/core_spec.lua`,
`tests/fixtures/core/mdt_dispatch.sql`. Each Lua file's header comment documents its public API.

## Contract interpretations

### CP.Qbx
- `onDutyChange(fn(src, onDuty))`: a `false` from `QBCore:Server:SetDuty` is passed on as is. A `true` is
  re-read from PlayerData before listeners run, so a stale `true` (sc-police / sc-ambulance forcing a
  suspended officer off duty inside their own handler) reaches listeners as `false`. Listeners are still
  expected to re-read before acting on "on duty" (§5.1).
- `onJobChange(fn(src, job))`: `job` is the live job in the `getInfo` shape
  (`{ name, label, type, onduty, gradeLevel, gradeName }`), not qbx's raw `{ grade = { name, level } }` table.
- Every listener (server and client, all integrations) runs in its own `CreateThread` inside `pcall`,
  so a listener may query the database or wait without holding up qbx_core's synchronous dispatch.
- `getInfo.callsign` is `nil` for a missing value, `''` and qbx_core's default `'NO CALLSIGN'`; it is
  trimmed but not clipped (Access clips to 32 when it builds the officer and writes the row).
  `gradeName` falls back to the grade name in the job definition (`GetJobs`) when the player's job has none.
- `getOnlinePlayers()` is cached for 1 s (GetQBPlayers copies every player's data); the cache is
  dropped on load, unload and drop.
- `addMoney(src, account, 0)` returns `true` without calling qbx_core (nothing to move). Negative,
  NaN or infinite amounts return `false`. Amounts are rounded half up.
- Client `onJobUpdate(fn(job))` also fires on `qbx_core:client:onGroupUpdate` with the re-read
  `PlayerData.job` (the only event when the active job is removed). Client `getPlayerData()` returns
  `{}` while `LocalPlayer.state.isLoggedIn == false` (qbx_core does not clear PlayerData on logout).

### CP.Dispatch
- `onResponding` listeners receive the callId exactly as sent (number or string, validated: no tables,
  at most 64 characters) and a real boolean. Use `normalizeCallId` / `lookupActiveCall` for keys.
- Net listeners are rate limited per player: ToggleResponding 6/s, ShotsFired/PlayerDown/PlayerDead 5/s.
- Alert listeners get a sanitised copy: `{ coords = vector3|nil, street, zone, sex }` (client-supplied:
  use server-side ped coords for distance checks). Payloads without `coords` are dropped (sc-dispatch
  creates no call for them either).
- `lookupActiveCall` returns `nil` when sc-dispatch is not started. The numeric parameter is the integer
  form only for digit-only ids (`'0x1a'`, `'1e3'` are not treated as numbers), `0` otherwise. An empty
  or NULL `unique_id` returns the row id as a string. `npccall-` rows ARE returned (caller classifies).
- `clearNotification` refuses numbers AND digit-only strings (`'123'` would also match unrelated
  ems/fire rows by row id in sc-dispatch's `id = ? OR unique_id = ?`), returns a boolean.
- `onDispatchRestart` fires for both `onResourceStart` and `onResourceStop` of `sc-dispatch`.

### CP.Ambulance
- `doctorCount()` = min(`GetDoctorCount()`, live count of on-duty `ambulance` players via
  `CP.Qbx.getOnlinePlayers` + `getInfo`) when the live list is available; export `0` always gives `0`.
- `revive(src)` returns a boolean; it refuses non-integer, non-positive and disconnected ids, and sends
  nothing while sc-ambulance is stopped (the event would have no handler).
- Client `sendEMSRequest()` returns a boolean and refuses a second request within 5 s.

### CP.Banking
- All four functions return booleans (`societyBalance` a number or nil) and never raise. `0` amounts are
  not sent (a $0 history entry) and return `true`. Title = `Config.Tablet.title`. The message has `'`
  and `\` removed; issuer/receiver are never nil (`''`).

### CP.Access
- An invalid `text` colour falls back to `CP.U.contrastText(background)` (with a warning) rather than the
  Crimson-Police default text colour, which could be unreadable on a light background. Missing `text`:
  contrast pick, no warning. Other invalid colours: Crimson-Police default (= `Config.AdminTheme`
  defaults / web `DEFAULT_THEME`), one warning per department and key, never repeated on rebuild.
- `logo.url` (https only) wins over `logo.file`; `file` must be a bare `png/webp/svg/jpg/jpeg` file
  name. `size` is clamped to 0.05-1. The sanitised dept also carries `logo.file` (nil for url logos).
- A department without a numeric `supervisorGrade` has no supervisors (warning); `societyAccount`
  defaults to the first job name (Renewed-Banking creates one account per job). A job listed in two
  departments belongs to the first key (sorted), with a warning.
- `department()` / `departments()` return copies.
- `getOfficer` returns `err.not_police` when the player has no loaded character. Crimson-Police and
  SC-Dispatch suspension lookups are cached for 15 s (`suspend()` updates the cache at once).
- `recheck(src, jobName)` returns `true` for a player without a character (the drop/unload path ends the
  run as `disconnected`).
- `onLost(fn(src, reason))` compares with the player's last known active job (seeded on start, load,
  getOfficer, recheck and every qbx event). It fires only for players whose last known job was a
  department job: `job_change` (different job, incl. unemployed), `off_duty`, `suspended`. It also fires
  `suspended` from `suspend()` for an online officer. Listeners decide whether the player is on a run.
- `suspend()` does not write the audit log (the calling module does). When `actorSrc` is a player it
  must pass `CP.Permissions.can(actorSrc, 'suspend')`; `0`/`nil` (console, anticheat) skip that. The
  online officer gets a toast (`access.suspended_notice` / `access.unsuspended_notice`). Days must be
  whole numbers 0-3650; citizenids `[%w_-]`, max 50 characters, used exactly as given.
- `refreshOfficerRow` also refreshes off-duty department members; civilians get no row. Runs on
  character load, on OnJobUpdate for a department job, and on Officer/Supervisor UI open.
- Export `GetDepartment(src)` returns the department of the active job whether or not the player is on
  duty or suspended.
- Client side: `CP.Access.current()`, `department()`, `roles()`, plus `setSession(session)` and
  `clear()` used by the tablet (both halves are this slice).

### CP.Permissions
- Admins (and the console) get `true` for any action name.
- `ctx` (optional): `runUuid` applies the own-run rule to `reviewFlagged`, `handleDisputes`,
  `handleFailedDispute`, `voidAnyRun` (admins included, `err.own_run`); `department` / `departments`
  (list or set) restricts supervisors to their department (`err.other_department`).
- `tookPart` fails closed on a database error (treated as a participant).

### CP.Tablet
- Supervisor UI: allowed for officers at/above `supervisorGrade` AND for on-duty officers who are
  admins; `roles.supervisor` reflects the same rule. `session.officer` is filled whenever the player
  qualifies as an officer, also in the Admin UI.
- `session.logo` is nil when the department has no valid logo or its file was missing at start.
  nil fields (callsign, logo, officer) arrive in the NUI as missing keys (undefined), not `null`.
- `getSession({ ui, silent = true })` skips `refreshOfficerRow` (used by the theme fetch at login).
  getSession is rate limited to 4/s per player.
- `switchUi` replies `{ ok, data = Session }` AND sends an `open` message for the new UI (the web
  handlers are idempotent). The prop stays when switching officer <-> supervisor and is removed for admin.
- The `theme` message always carries a theme object (the Crimson-Police default when the player is not
  an officer) plus `locale`; it is sent at login, after duty/job changes (debounced 1.5 s), on unload
  and on NUI `ready` (which also re-sends the HUD, overlay and open UI).
- `hud(patch)`: shallow merge; setting a nullable field (`modifier`, `timer`, `route`, `message`,
  `detail`) to `false` clears it. `hud(nil)` sends `{ type = 'hud' }` (hud missing = null).
- The command toggles the Officer UI. The key mapping is `crimsonpolice_tablet` (rule 14 prefix),
  always registered with default key `Config.Tablet.keybind` (`''` = unbound, bindable in GTA settings).
- Prop: `Config.Tablet.prop`, networked (local fallback under entity lockdown), bone 60309 with the
  offsets tuned for `amb@code_human_in_bus_passenger_idles@female@tablet@base` / `base` (flag 49); the
  animation is re-applied every second while the UI is open if something cleared it.
- The NUI `action` endpoint only forwards names starting with `server:`.
- Client-only extra: `CP.Tablet.push(topic, data)` for local live updates.
- `openAdmin(src)` runs synchronously inside a thread, otherwise in its own thread (returns `true`).
  From the console it returns `false, 'err.not_in_game'`.
- `server:logoFailed` accepts a department key or `{ department, url }` (the web sends the latter;
  a null department is matched by url).
- The tablet client does not handle `client:hud` / `client:runEnded` (see requests).

## Requests to other modules

- **runs (client)**: forward `crimson-police:client:hud` (runId, patch) to `CP.Tablet.hud(patch)` and
  `client:runEnded` to `CP.Tablet.result(result)`; call `CP.Tablet.hud(nil)` when the run is over.
  To clear a nullable HUD field send `false` (Lua cannot send nil inside a table).
- **runs (server)**: register `CP.Access.onLost` for immediate `off_duty` / `job_change` / `suspended`
  removals (ignore players not on a run), keep `CP.Access.recheck(src, p.job)` as the 10 s backstop, and
  `CP.Qbx.onPlayerUnload` for `disconnected`.
- **admin**: write the audit entry for `server:admin:suspend` and the console `suspend` subcommand
  (`CP.Access.suspend` does not audit). Pass the citizenid exactly as stored (Qbox citizenids can
  contain lower-case letters). `CP.Tablet.openAdmin(src)` may be called from the command handler.
- **anticheat**: auto-suspension = `CP.Access.suspend(citizenid, Config.AntiCheat.suspendDays, 0, 'auto')`
  plus its own audit entry.
- **cash**: pay pending cash in a thread ~5 s after `CP.Qbx.onPlayerLoaded` (Renewed-Banking loads the
  player's history cache asynchronously; `recordDeposit` returns true even when it silently drops the
  entry). Re-fetch the player right before `CP.Banking.withdrawSociety` (there is no refund call in the
  contract: Renewed-Banking's `addAccountMoney` is not listed). Only call `recordDeposit` when
  `Config.Cash.account == 'bank'`; transId `('CP-%s-%s'):format(runUuid, citizenid)`.
- **calls**: test the `npccall-` prefix (plain find) before `lookupActiveCall` and again on the id it
  returns; key the responding map by the returned canonical id.
- **alerts**: `onShotsFired` data is client-supplied; use `GetEntityCoords(GetPlayerPed(src))`, capture
  nothing else before waiting (`receivedAt` is already the arrival time), clear `t-1`, `t`, `t+1`.
- **downed**: `CP.Ambulance.revive` returns false when sc-ambulance is stopped; `sendEMSRequest` refuses
  a duplicate within 5 s.
- **operations / everyone**: `CP.Tablet.notify` and `push` never broadcast to -1; use `notifyMany` with a
  list of sources.
- **web**: `session.logo` / `officer.callsign` may be missing (undefined); the `theme` message always has
  a theme; `switchUi` also produces an `open` message; `logoFailed` payload `{ department, url }` is right.
- **locale merge**: `core.json` also defines the shared-layer keys `err.internal`, `err.rate_limited`,
  `err.refused`, `err.timeout`, `err.no_response` (returned by `shared/net.lua` through the NUI bridge)
  and the `tier.*` labels; other parts defining them must use the same text.
