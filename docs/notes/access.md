# Access & UI shell (WP8) · tablet ways, mission desks, badges, the bell, the officer's look and Config health

What WP8 added on top of the foundation. WP9 copies the API rows below into docs/ARCHITECTURE.md. English is the
only language in this build (owner decision): the per-player language engine, the convar follow, plurals, CP.Lp,
check_contracts --locales, the per-language merge, locale injection on the client and the CP.L → CP.Lt conversion of
the engine's HUD and board-card text were not built. Tokens keep resolving in the server language (foundation.md).

## Tablet access (modules/tablet/server.lua)

getSession args: `{ ui, via = 'command'|'keybind'|'item'|'export'|'desk'|'dispatch', desk = index, silent }`. For the
Officer and Supervisor UIs every way ends in `T.checkAccess(src, officer, via, desk)` after CP.Access.getOfficer
(department, duty, suspensions):

| Rule | Error |
|---|---|
| A way whose Config.Tablet.access switch is false (dispatch follows keybind; item also needs Config.Tablet.item; export is always on) | err.access_off |
| CP.Alerts.inArena(src), for every way | err.in_arena |
| Desk: the index names no Config.Tablet.desks entry (spoofed, 0, negative, not whole) or the ped is outside the box grown by 2 m (server coordinates; `rotation` turns the box, z included) | err.not_at_desk |
| Desk: departments set and the officer's department not in it | err.desk_department |
| requireItem: every way but a desk needs the item; ox_inventory Search(src, 'count', item) in pcall, a failed lookup or a stopped ox_inventory counts as no item (only while requireItem is on) | err.no_tablet_item |

- The silent session (the HUD theme at login) opens nothing and skips these checks. An unknown `via` is the command.
- A request that names no way (switchUi, refreshSession) is checked with the way of the last session that passed for
  that src (`lastWay`), so walking away from a desk and switching UI is refused.
- `T.desk(i)`, `T.deskAllows(desk, dept)`, `T.inDeskBox(desk, coords, margin)`, `T.hasTabletItem(src)`,
  `T.checkAccess(...)`.
- Net: plain `crimson-police:server:tabletItemGone` (the client saw the item go): with requireItem on, not opened at a
  desk and the item really gone, the server sends `crimson-police:client:closeTablet` (errKey) to that player.
- Callback `admin:getTabletAccess` (admins) → TabletAccessView (web/src/types/access.ts): ways, item, deskDistance,
  desks (index, label, coords, size, rotation, departments or nil, prop), each department's personal accents and the
  appearances.

## Sidebar badges (modules/tablet/server.lua)

`T.navCounts(src) -> NavCounts` and callback `getNavCounts`. Each count through a guarded call (a missing or failing
module gives 0): invites (CP.Units.invitesFor, else the open invites of CP.Units.view), calls
(CP.MissionCalls.claimableCount), review (supervisors only: CP.Admin.flaggedRows(dept, own citizenid) with
reviewFlagged, CP.Disputes.forSupervisor with handleDisputes, CP.Profile.queue(dept) with reviewProfiles; 30 s cache per
src), commendations (CP.Profile.newCommendations), rewards (CP.Rewards.lockerCount), onRun (CP.Runs.getBySrc). The
whole set is cached 5 s per src.

Push 'nav': every CP.Tablet.push of unit, invites, calls, profile, rewards or run clears that src's cache and, when
the src asked getNavCounts or opened the tablet in the last 10 minutes, schedules one 'nav' push 1 s later (a burst is
one push). An open tablet asks getNavCounts again every 5 minutes (navBadges.ts). Cleared on playerDropped.
server:tabletItemGone is rate limited (2 a second per src).

## Client (modules/tablet/client.lua)

- `T.open(ui, opts)`: opts `{ via, desk, screen }` (via defaults to 'export'); the command names 'command', the key
  mapping 'keybind', the item 'item', the OpenTablet export 'export', a desk 'desk'. The open NUI message carries
  `screen`.
- Key mapping `crimsonpolice_dispatch` (Config.Tablet.dispatchKey, unbound): opens the Officer UI on Dispatch, or
  switches an open Officer UI to it.
- Mission desks: one ox_target addBoxZone per desk (option `crimson-police:desk`, 2 m), created once at start and
  again only after they were removed; canInteract shows it only to an on-duty officer of an allowed department, with
  the tablet closed and outside Crimson-Arena (display only: the server decides). An optional local laptop prop
  (never networked) per desk. Removed on resource stop and when a foreign crimsonArena value appears; created again
  when the arena lets the player go. `T.deskZones()`.
- At a desk: no handheld prop or animation; Config.Tablet.deskScenario plays, and the tablet closes when the player is
  more than Config.Tablet.deskDistance from the desk's box (0 inside it, rotation included; checked every 0.5 s); the
  scenario is cleared on close.
- requireItem: while the tablet is open (not at a desk) the client looks for the item every second
  (exports.ox_inventory:Search('count', item), pcall) and reports its loss once through server:tabletItemGone.
- Net: `crimson-police:client:closeTablet` (errKey) closes the Officer or Supervisor UI with a toast.

## Config health (modules/confighealth/server.lua)

`CP.ConfigHealth.register(name, fn -> { { level = 'ok'|'warn'|'error', text } })` (a second register of a name
replaces it), `run() -> ConfigHealthItem[]` (errors first, then warnings, then ok; a failing check is one error line),
Runs 5 s after start (and registers CP.Rewards.health then); only the first run prints its problems to the console.
Callback `admin:getConfigHealth` (admins) runs every check again, so "Check again" shows a fix at once.

Built-in checks: items (the tablet item in ox_inventory, requireItem without an item, the item way off, no
ox_inventory), desks (coords, size, unknown departments, ox_target running, off), colours (each department theme's four
colours, personalAccents colours, levels and duplicates), tweaks (Config.MissionTweaks ids and whether each was applied),
locale (locales/en.json loads; Config.Locale other than en warns: English only), avatars (links on with no valid host,
bad host names, expiring hosts such as cdn.discordapp.com, no approval).

## Web

- layouts/TabletFrame.tsx: `prefs` and `profile` props; mergeAppearance (theme.ts) applies the appearance
  (department, midnight, high_contrast, colourblind) and a personal accent that is one of the department's; the primary
  colour, logo and watermark stay the department's; colourblind and high contrast set extra status and text colours
  (applyAppearance). The tablet size is Prefs.uiScale clamped to Config.Profile.uiScale, never larger than the
  viewport (`clampUiScale`, `tabletScale(width, height, uiScale)`).
- layouts/Header.tsx: the officer's Avatar and "Lv n" (band in the tooltip) next to the callsign; the bell
  (layouts/NotificationBell.tsx: the last 20 toasts of the NUI session from the toast bus, unseen count), also in the
  Admin UI header (layouts/AdminLayout.tsx).
- layouts/Sidebar.tsx: `live` dot; layouts/navBadges.ts: `useNavCounts()` (getNavCounts + push 'nav') and
  `navBadge(key, counts)`: Home rewards, Dispatch calls, Unit invites, Active Mission live dot, Profile commendations,
  Review Queue open items.
- OfficerLayout mounts the ReadyCheckBanner above every screen but Unit (which has its own) and refreshes the session on
  a 'profile' push, so a saved look applies at once. Both tablet layouts call setMoneyFormat(session.config.format).
- shared/format.ts: `setMoneyFormat`, formatMoney follows Config.Format (currency, currencyAfter), `fmtPlain` (Form.tsx
  NumberInput ranges), formatDateTime through the locale's date locale.
- shared/data.ts: normalizeSession keeps the parity-plus config values (dispatch, profile, format ...), which it dropped.
- Admin UI: Permissions shows Config health; Departments lists each department's personal accents and mission desks and
  previews every look (appearance and accent) in the theme preview.
- Browser mock (mocks/core.mock.ts): getNavCounts, admin:getConfigHealth, admin:getTabletAccess; the session carries
  the officer's look from the profile mock; `?uiScale=0.85`, `?uiScale=1.25`, `?look=<appearance>`, `?accent=%23rrggbb`.

## Item files

items/crimson_police_tablet.png, items/ox_inventory_items.lua (the ox_inventory entry, client.export
'Crimson-Police.useTablet'; never loaded by the resource), items/README.md.

## Tests

tests/access_spec.lua: every way refused when off, desk box ± margin (rotated box, a floor above), department desk,
spoofed indices, arena, the remembered way, requireItem with and without the item and with a failing Search,
tabletItemGone, navCounts aggregation, caches, failing and missing modules, the coalesced 'nav' push, admin
getTabletAccess, each Config health check's levels, the registry, and on the client: zones created once, canInteract,
the desk pose and distance close, the ways named, the Dispatch key, the item watcher, arena removal and return, and the
resource stop.
