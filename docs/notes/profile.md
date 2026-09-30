# Profile (WP6) · pictures, bio, look, reports, commendations and moderation

What `modules/profile/server.lua` adds. WP9 copies the API rows below into docs/ARCHITECTURE.md. English is the only
language in this build: a profile has no language choice (the column exists; it can only be cleared).

## CP.Profile (server)

| Function | Meaning |
|---|---|
| `avatarOf(row, { own }) -> Avatar` | Pure: the picture from a cp_officers row (approved link or preset, else initials; frame = the level badge). A hidden name (hide_name) shows the callsign's initials and never the picture unless `own` |
| `avatarFor(citizenid, viewerSrc|nil) -> Avatar` | The same, read from the database; `own` when the viewer is that officer |
| `prefsFor(citizenid) -> Prefs` | appearance, accent, uiScale (clamped to Config.Profile.uiScale), language (nil), callsMuted |
| `languageFor(citizenid) -> nil` | Always the server language in this build |
| `commendations(citizenid, { staff, viewer }) -> Commendation[]` | Active ones newest first; `staff` adds revoked ones with issuedBy and revokeReason; `viewer` (a citizenid) adds `mine` (that viewer issued it). An issuer who hides their name is shown by callsign, without a rank, except to staff |
| `newCommendations(citizenid) -> n` | Commendations of the last Config.Commendations.announceDays days (60 s cache) |
| `report(src, citizenid, reason, note) -> ok, err` | Report profile (picture, bio, other; note ≤ Config.Profile.reports.reasonMax). Never your own; one per profile per reporter per day; Config.Profile.reports.perDay per reporter per day (counted from cp_profile_reports); audited (profileReport) |
| `validateBio(text) -> text|nil|false, err` | ≤ bioMax characters and bioLines lines, CRLF → LF, control characters removed, trimmed, no word of Config.Profile.bannedWords or config/banned_words.txt (whole words or phrases, any case) |
| `validateUrl(url) -> ok, err` | https, exact host from avatarUrls.hosts, ≤ 255 characters, path ending .png/.jpg/.jpeg/.webp (the query string is ignored), no spaces, quotes, backticks, backslashes or angle brackets |
| `set(officer, payload)`, `editView(officer)`, `queue(dept|nil)`, `adminView(citizenid)` | The handlers below |

## Net

| Name | Payload → reply | Rules |
|---|---|---|
| callback `getProfileEdit` | → ProfileEdit (+ bioPending) | own |
| action `server:profile:set` | `{ bio?, avatar? = { kind, value }, appearance?, accent?, uiScale?, language?, callsMuted? }` → `{ pending = { avatar, bio } }` | Picture and bio changes share Config.Profile.editCooldown (profile_updated_at); the look and the mute do not. A preset above the officer's level is refused; a link needs avatarUrls.enabled, counts toward avatarUrls.perDay (in memory, per day) and with requireApproval waits in avatar_pending while everyone keeps the old picture. With bioRequiresApproval a bio waits in bio_pending. accent: only the department's theme.personalAccents at or below the level (false clears). The mute saves cp_officers.calls_muted and clears CP.MissionCalls' mute cache |
| action `server:profile:report` | `{ citizenid, reason, note? }` | any officer |
| `server:sup:reviewAvatar` / `server:admin:reviewAvatar` | `{ citizenid, decision = 'approve'|'reject', reason, what? = 'avatar'|'bio' }` | reviewProfiles, the officer's department (admins any), never your own profile, reason required; a claim UPDATE on the pending value; audited reviewAvatar / reviewBio; the officer gets a toast |
| `server:sup:clearProfile` / `server:admin:clearProfile` | `{ citizenid, what = 'bio'|'avatar', reason }` | same rules; audited clearBio / clearAvatar |
| `server:sup:handleReport` / `server:admin:handleReport` | `{ id, decision = 'clear'|'dismiss', reason }` | same rules on the report's department; clear also clears the reported picture or bio; audited clearReport / dismissReport; final once handled |
| `server:sup:commend` / `server:admin:commend` | `{ citizenid, kind, citation, runUuid? }` → `{ id }` | issueCommendation (sup) / openAdmin. Kind from Config.Commendations.kinds, citation length from `citation`, never yourself. Supervisors: own department unless crossDepartment, perSupervisorPerDay. Everyone: sameKindCooldownDays; a run must be the recipient's (CP.Permissions.tookPart) and never the issuer's. Zero points: nothing but cp_commendations and the audit row is written. Toast, Home news, optional board webhook (announce) |
| `server:sup:revokeCommendation` / `server:admin:revokeCommendation` | `{ id, reason }` | the issuer (sup) or any admin; audited |
| callback `sup:getProfileQueue` | `{ department? }` → ProfileQueueItem[] (+ note, current) | reviewProfiles; supervisors get their department, admins every department (or the one they pass). Reports show the live picture and bio, never the reporter |
| callback `admin:getOfficerProfile` | `{ citizenid }` → the staff profile: LB.profile with `{ staff = true }` plus realName, bioPending, pendingAvatar, avatarStatus, every commendation, open reports | openAdmin |

Push `profile` (`{ citizenid }`) goes to the officer after every change to their profile.

## Hooks

- `home:extras`: `extras.commendations` (count) and `extras.news` (`{ kind = 'commendation', text, at }`), read from the
  cache only; a missing or stale entry is loaded in a thread for the next Home refresh.
- `officer:loaded`: warms the commendation cache.

## Web

`shared/components/Avatar.tsx` (presets from `web/src/assets/avatars/*.svg`, links fall back to the initials on an error),
`officer/components/ProfileEditDialog.tsx`, `CommendationsCard.tsx`, `ServiceRecordCard.tsx`, `LookCard.tsx` (the own
profile's Look card, read through getProfileEdit) (+ `ProfileCards.css`),
`supervisor/components/CommendDialog.tsx`, `ProfilesReview.tsx`. The Edit profile dialog has no language picker (English
only). Browser mocks: `mocks/profile.mock.ts` (it also adds the profile values of getSession to the mock session).

## Tests

tests/profile_spec.lua (every rule above, in all three storage modes). Bios in the spec are single-line: the harness's
mysql client splits a value holding a newline into rows (database mode only), so multi-line bios are checked through
validateBio.
