# Crimson-Police · web UI

React 18 + TypeScript + Vite 6. Builds into `web/dist`, which FiveM loads as
`ui_page 'web/dist/index.html'` of the resource **Crimson-Police**. `dist/` is committed, so rebuild
and commit it after every UI change.

One page holds everything: the Officer and Supervisor UIs (a tablet in the department theme), the
Admin UI (a full-screen panel in the admin theme), the mission HUD, the result card, toasts and
overlays. The page itself is fully transparent (the game is drawn behind it) and renders nothing
while nothing is active.

```
npm install
npm run dev         # browser dev mode on http://localhost:5173 (mocks + dev panel)
npm run build       # tsc --noEmit && vite build → dist/ (must pass with zero errors)
npm run typecheck
```

No component libraries, CSS frameworks or router: plain CSS with CSS variables, a state-based screen
switch, and no remote fonts or URLs anywhere (FiveM may be offline).

---

## Layout of `src/`

```
main.tsx                  boot: loads mocks in browser mode, renders <App/>
App.tsx                   all Lua-driven state (session, ui, hud, result, toasts, overlay, theme)
shared/
  types.ts                every NUI shape (ARCHITECTURE §9.2–9.6) + Notification, Overlay, UiKind, ApiResult
  nui.ts                  the bridge: fetchNui, request, action, clientAction, useNuiEvent, registerMock, emitDebug
  hooks.ts                useRequest, useAction, useCountdown, usePush, useEscapeLayer, useViewport …
  i18n.tsx                LocaleProvider, t(), useT(), tOr(), hasKey()
  theme.ts                applyTheme(), themeVars(), DEFAULT_THEME, colour helpers
  session.tsx             useSession(), useCan(), useTablet(), officerLine()
  navigation.tsx          useNavigate(), useNavigation(), ScreenKey
  format.ts toast.ts cx.ts
  components/             the shared toolkit (index.ts exports everything)
  index.ts                re-exports all of the above: import { … } from '../../shared'
layouts/                  TabletFrame, Header, Sidebar, RunBar, Officer/Supervisor/AdminLayout, screens.ts
officer/screens/          Home, MissionBoard, Unit, ActiveMission, Leaderboard, Challenge, Profile
supervisor/screens/       MissionList, CrossDept, LiveMissions, ReviewQueue, Payouts, Builder, DeptReport
admin/screens/            Payouts, Missions, Seasons, Leaderboards, Officers, Departments, Permissions, Audit, Testing
hud/                      Hud, ResultScreen, FadeOverlay, HudColumn (done) · TestControls, DebugOverlay, BuilderOverlay (stubs)
mocks/                    browser-only: index.ts (loads *.mock.ts), core.mock.ts, samples.ts, DevPanel, Gallery
styles/                   base.css (tokens), components.css, layouts.css, hud.css
```

---

## Adding a screen (screen owners)

Each screen is **one file** that already exists as a stub. Replace only that file; the registry
(`layouts/screens.ts`), layouts and sidebar never need edits.

1. **Replace the stub.** Keep the default export and no props:

   ```tsx
   import { Screen, Card, Table, Button, Money } from '../../shared/components';
   import { useRequest, useAction } from '../../shared/hooks';
   import { t } from '../../shared/i18n';
   import { useNavigate } from '../../shared/navigation';
   import type { BoardData } from '../../shared/types';

   export default function MissionBoard() {
     const { data, loading, error, refetch } = useRequest<BoardData>('getMissionTypes', {}, { pushTopic: 'board' });
     const { run, busy } = useAction();
     const navigate = useNavigate();
     const accept = async (type: string) => {
       const res = await run('server:acceptType', type, { success: 'board.accepted' });
       if (res.ok) navigate('active');
     };
     return <Screen title={t('ui.screen.board')}>…</Screen>;
   }
   ```

   Screen keys (for `navigate`) and title keys (`ui.screen.<key>`):

   | UI | keys (sidebar order) |
   |---|---|
   | Officer | `home` `board` `unit` `active` `leaderboard` `challenge` `profile` |
   | Supervisor | `sup_missions` `sup_crossdept` (launchCrossDept) `sup_live` (forceRecall) `sup_review` (reviewFlagged or handleDisputes) `sup_payouts` (setTypePayout) `sup_builder` (builderEdit) `sup_report` |
   | Admin | `admin_payouts` `admin_missions` `admin_seasons` `admin_leaderboards` `admin_officers` `admin_departments` `admin_permissions` `admin_audit` `admin_testing` |

   `navigate(key, params)` passes params; read them with `useNavigation().params`
   (e.g. Leaderboard → `navigate('profile', { citizenid })`). Keys of another UI are ignored.

2. **Mocks** for browser mode go in a new file `src/mocks/<feature>.mock.ts`. Every `*.mock.ts` is
   loaded automatically:

   ```ts
   import { registerMock } from '../shared/nui';
   import { sampleResult } from './samples';
   registerMock('request', 'getProfile', (citizenid) => ({ …, runs: [{ …, breakdown: sampleResult('completed') }] }));
   registerMock('action', 'server:acceptType', (type) => {
     if (type === 'tactical') throw new Error('err.server_busy');   // → { ok: false, error: 'err.server_busy' }
     return { runId: 'x' };
   });
   ```

   A mock returns the data (or a Promise); throwing an `Error('err.<key>')` answers with that error.
   `core.mock.ts` registers `getSession`, a fallback `getRun` (overridden by any real `getRun`
   mock) and `logoFailed`.

3. **Text** goes in your own locale part `Crimson-Police/locales/parts/<slice>.json` (flat JSON
   object, your namespace from ARCHITECTURE §10). Never hard-code English; never edit another
   slice's part. Browser mode merges every part automatically.

4. **Styles**: put screen CSS in a sibling file (e.g. `officer/screens/MissionBoard.css`) imported by
   your screen, prefix classes with your feature (`.board-…`) and use only the `--cp-*` variables
   below so every department theme works.

5. Run `npm run build` (zero TypeScript errors) and commit `dist/`.

---

## NUI transport (ARCHITECTURE §9.1)

**Lua → NUI**: `SendNUIMessage({ type = …, … })`, received as window `message` events.

| type | fields | effect |
|---|---|---|
| `open` | `ui`, `session`, `screen?` | show that UI (optional screen key to open) |
| `close` | — | hide the UI (HUD stays) |
| `session` | `session` | replace the session |
| `notify` | `notification = { id, kind, title?, text, duration }` | toast (text already translated) |
| `hud` | `hud = HudState \| null` | mission HUD (full state; null hides) |
| `result` | `result = RunResult \| null` | result card for 25 s (null hides) |
| `push` | `topic`, `data` | live updates: `run` `unit` `board` `operation` `invites` `test` `builder` `payouts` |
| `overlay` | `overlay = null \| { kind, … }` | `fade { text }`, or builder kinds `placement` `recording` `testdrive` |
| `theme` | `theme`, `locale?` | the officer's department theme at login (HUD/toasts); optional locale for text before the first session |

**NUI → Lua**: `POST https://<GetParentResourceName() or 'Crimson-Police'>/<endpoint>` with JSON.

| endpoint | body | reply |
|---|---|---|
| `ready` | `{}` | `{ ok }` — sent once on mount |
| `close` | `{}` | `{ ok }` — Escape (when no dialog is open) or the close button |
| `request` | `{ name, args }` | `{ ok, data?, error? }` — callback `crimson-police:<name>` |
| `action` | `{ name, payload }` | `{ ok, data?, error? }` — net event `crimson-police:<name>` |
| `client` | `{ name, payload }` | `{ ok, data?, error? }` — `CP.Tablet.registerClientAction` |
| `switchUi` | `{ ui }` | `{ ok, data: Session }` |

Client actions the foundation calls: `logoFailed { department, url }` (once per failing logo URL).

Bridge API (`shared/nui.ts`), all resolving (never rejecting) to `{ ok, data?, error? }`:

- `request<T>(name, args)`, `action<T>(name, payload)`, `clientAction<T>(name, payload)`, `fetchNui<T>(endpoint, body)`
- `useNuiEvent(type, handler)` — handler gets the whole message (`m.hud`, `m.topic`, …)
- `isEnvBrowser()`, `resourceName()`, `registerMock(kind, name, fn, { fallback? })`, `emitDebug(type, fields, delayMs?)`
- Network failures map to `err.no_response`, 20 s without a reply to `err.timeout`.

## Hooks (`shared/hooks.ts`)

| hook | returns / does |
|---|---|
| `useRequest<T>(name, args, { pushTopic?, pollMs?, skip? })` | `{ data, loading, error, refetch, setData }`; refetches when `args` change (by value), on push `pushTopic` and every `pollMs`; keeps old data while refetching |
| `useAction()` | `{ run(name, payload, { success?, successVars?, silent? }), busy }`; failed actions toast `t(error)` |
| `useCountdown(seconds, { paused?, resetKey?, onDone? })` | seconds left, counting down locally; restarts when `seconds`/`resetKey` change |
| `usePush(topic, handler)` | handler(data) for each `push` of that topic |
| `useEscapeLayer(active, onEscape)` | Escape closes this layer before the UI (Dialog uses it) |
| `useViewport()`, `useHudScale()`, `usePrevious()` | helpers |

Session and navigation: `useSession()` (the Session), `useCan()` → `can('forceRecall')`,
`useTablet()` → `{ close, switchUi, refreshSession, ui }`, `useNavigate()`, `useNavigation()`.

Text: `t(key, vars)` (module level, also fine in components) replaces `{var}`; unknown keys render
the key. `useT()` is the hook form, `tOr(key, fallbackKey)` picks a fallback key, `hasKey(key)`.

Formatting (`shared/format.ts`): `formatMoney(1040)` → `$1,040`, `formatNumber`, `formatMultiplier`
(`×1.30`), `formatDuration` (`8:02`), `formatDistance`, `formatPercent`, `formatDateTime`.
Toasts from code: `toast(kind, text, { title?, duration? })` (`shared/toast.ts`).

## Theme variables

`applyTheme(el, theme)` (`shared/theme.ts`) validates 6-digit hex per key (default: the
Crimson-Police theme `#a4161a / #e5383b / #0b090a / #161a1d / #f5f3f4`) and sets:
`--cp-primary --cp-accent --cp-bg --cp-surface --cp-text`, derived `--cp-surface-2 --cp-surface-3
--cp-border --cp-border-strong --cp-muted --cp-subtle --cp-primary-contrast --cp-accent-contrast
--cp-primary-hover --cp-primary-text --cp-accent-text`, and `--cp-*-rgb` triplets for `rgba()`.
Fixed tokens: `--cp-success/warning/danger/info` (+ `-rgb`), `--cp-xp-<badge>`, `--cp-tier-<tier>`,
`--cp-radius*`, `--cp-fs*`, `--cp-shadow*`. Numbers use the `.cp-num` class (tabular figures).
Avoid `color-mix()`, CSS nesting and `:has()` (FiveM's CEF may be older).

## Components (`shared/components`)

| Component | Props |
|---|---|
| `Button` | `variant` primary\|secondary\|ghost\|danger, `size` sm\|md, `loading`, `icon`, `iconRight`, `block`, button attrs |
| `IconButton` | `icon`, `label` (required, aria + tooltip), `variant`, `size`, `loading` |
| `Card` | `title`, `subtitle`, `icon`, `actions` (header slot), `footer`, `padding` none\|sm\|md\|lg, `highlight` primary\|accent\|success\|warning\|danger, `muted`, `onClick` (becomes keyboard-clickable) |
| `Screen` | `title`, `subtitle`, `actions` — standard page wrapper for every screen |
| `Section` | `title`, `description`, `actions` |
| `Grid` / `Stack` / `Row` / `Spacer` / `Divider` / `KeyValue` | `Grid cols={3}\|"2fr 1fr"`, `min={220}` (auto-fill), `gap` (4px steps); `Stack direction gap align justify wrap grow` |
| `Badge` | `tone` neutral\|primary\|accent\|success\|warning\|danger\|grey\|bronze\|silver\|gold\|platinum, `variant` soft\|solid\|outline, `size`, `icon`, `dot` |
| `TierBadge` | `tier` (standard…critical), `label?`, `expected?`, `size` |
| `XpBadge` | `badge` (Config.XPLevels colour), `label` |
| `Tabs` / `SegmentedControl` | `items [{ key, label, icon?, badge?, disabled? }]`, `value`, `onChange`; arrow keys move |
| `Table` | `columns [{ key, header, render?, width?, align?, numeric? }]`, `rows`, `rowKey?`, `onRowClick?`, `highlightRow?`, `empty?`, `loading?`, `stickyHeader` (default true), `maxHeight?`, `dense?`, `footer?` |
| `Dialog` | `open`, `onClose`, `title`, `description`, `footer`, `size` sm\|md\|lg, `dismissible` — renders inside the tablet, Escape closes it first |
| `ConfirmDialog` | `open`, `title`, `message`, `confirmLabel`, `tone` primary\|danger, `reason` (true or `{ label, placeholder, required, maxLength }`), `onConfirm(reason)` (may return a Promise → spinner), `onCancel`, `busy` |
| `Field` | `label`, `hint`, `error`, `required`, `inline` — wires ids/aria for the control inside |
| `TextInput` / `SearchInput` | `value`, `onChange(string)`, `prefix`, `suffix`, `invalid`, `onEnter`, input attrs |
| `NumberInput` | `value (number\|null)`, `onChange`, `min`, `max`, `step`, `integer` (default true), `prefix`, `suffix`, `formatRange` (e.g. formatMoney), `showRange`, `stepper`, `onValidityChange` — shows "Between min and max", refuses out-of-range input (onChange is never called with it) |
| `Select` | `value`, `onChange`, `options [{ value, label, disabled? }]`, `placeholder` |
| `Textarea` | `value`, `onChange`, `rows`, `maxLength`, `showCount` |
| `Toggle` / `Checkbox` | `checked`, `onChange(bool)`, `label`, `description` (Toggle), `disabled`, `indeterminate` (Checkbox) |
| `ProgressBar` | `value`, `max`, `tone`, `size` sm\|md\|lg, `label`, `showValue` |
| `Stat` | `label`, `value`, `hint`, `icon`, `tone`, `size` |
| `EmptyState` / `ErrorState` / `LoadingBlock` / `Spinner` | `title`, `text`, `icon`, `action`, `compact` / `error`, `onRetry` / `text` / `size` |
| `Countdown` | `seconds`, `paused`, `resetKey`, `warnBelow`, `dangerBelow`, `onDone` |
| `Money` / `MoneyRange` / `Points` | `amount`, `sign` / `range [min, max]` → `$1,040–$1,300` / `value`, `sign`, `suffix` |
| `Icon` | `name` (see `ICON_NAMES`), `size`, `label` |
| `Watermark` / `DeptLogo` | `logo`, `department` — used by the layouts; hide on load error and report `logoFailed` |
| `Toasts`, `ErrorBoundary`, `ScreenStub`, `LayerRootContext` | used by App/layouts |

## Browser dev mode

`npm run dev` and open http://localhost:5173. The dev panel (bottom left, browser only) opens the
three UIs, switches department (SAST, FIB, BCSO with a broken logo), sends sample HUD states
(in progress, off route, test run), results (completed, failed, flagged, test), toasts, the fade
overlay, the pinned run bar, and opens a **component gallery** of every shared component.

URL shortcuts: `?ui=officer|supervisor|admin&dept=sast|fib|bcso&screen=<key>&hud=progress|offroute|test`
`&result=completed|failed|flagged|test&run=1&toast=info&gallery=1&bg=night|day|none&dev=0`.

None of it ships into the game path: `main.tsx` imports `src/mocks` and `App` lazy-loads the dev panel
only when `isEnvBrowser()` (no `window.invokeNative`).
