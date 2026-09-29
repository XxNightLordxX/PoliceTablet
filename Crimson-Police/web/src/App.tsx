// src/App.tsx · NUI root. Owns every Lua-driven state (session, open UI, HUD, result, toasts,
// overlay, HUD theme) and renders the right layout. Nothing renders while nothing is active, and
// the page itself stays transparent (the game is drawn behind it).
import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useState, type CSSProperties } from 'react';
import { AdminLayout } from './layouts/AdminLayout';
import { OfficerLayout } from './layouts/OfficerLayout';
import { SupervisorLayout } from './layouts/SupervisorLayout';
import { defaultScreen, screensFor } from './layouts/screens';
import { TABLET_H, TABLET_W, tabletScale } from './layouts/TabletFrame';
import BuilderOverlay from './hud/BuilderOverlay';
import DebugOverlay from './hud/DebugOverlay';
import { FadeOverlay } from './hud/FadeOverlay';
import { Hud } from './hud/Hud';
import { HudColumn } from './hud/HudColumn';
import { ResultScreen } from './hud/ResultScreen';
import { Toasts } from './shared/components';
import { closeTopLayer, useHudScale, usePush, useViewport } from './shared/hooks';
import { LocaleProvider, t } from './shared/i18n';
import { NavigationContext, type NavigationValue, type ScreenKey, type ScreenParams } from './shared/navigation';
import { fetchNui, isEnvBrowser, request, useNuiEvent } from './shared/nui';
import { SessionContext, type SessionContextValue } from './shared/session';
import { applyTheme, DEFAULT_THEME } from './shared/theme';
import { normalizeHud, normalizeResult, normalizeSession } from './shared/data';
import { pushNotification, subscribeToasts, toast, TOAST_DEFAULT_MS } from './shared/toast';
import type { HudState, Notification, Overlay, RunResult, Session, Theme, UiKind } from './shared/types';

// Browser dev mode only (never loaded inside FiveM).
const DevPanel = isEnvBrowser() ? lazy(() => import('./mocks/DevPanel')) : null;

const MAX_TOASTS = 5;
let readySent = false;

type ScreenState = Record<UiKind, { key: ScreenKey; params: ScreenParams }>;

const initialScreens = (): ScreenState => ({
  officer: { key: defaultScreen('officer'), params: {} },
  supervisor: { key: defaultScreen('supervisor'), params: {} },
  admin: { key: defaultScreen('admin'), params: {} },
});

export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [ui, setUi] = useState<UiKind | null>(null);
  const [hud, setHud] = useState<HudState | null>(null);
  const [result, setResult] = useState<RunResult | null>(null);
  const [resultSeq, setResultSeq] = useState(0);
  const [toasts, setToasts] = useState<Notification[]>([]);
  const [overlay, setOverlay] = useState<Overlay | null>(null);
  const [hudTheme, setHudTheme] = useState<Theme | null>(null);
  const [bootLocale, setBootLocale] = useState<Record<string, string> | null>(null);
  const [debug, setDebug] = useState<unknown>(null);
  const [screens, setScreens] = useState<ScreenState>(initialScreens);
  const [switching, setSwitching] = useState(false);
  const hudScale = useHudScale();
  const viewport = useViewport();

  // ── Lua → NUI ──────────────────────────────────────────────────────────────
  useEffect(() => {
    if (readySent) return;
    readySent = true;
    void fetchNui('ready', {});
  }, []);

  const addToast = useCallback((n: Notification) => {
    if (!n || !n.text) return;
    const kind = n.kind ?? 'info';
    const item: Notification = { ...n, kind, duration: typeof n.duration === 'number' ? n.duration : TOAST_DEFAULT_MS[kind] ?? 5000 };
    setToasts((list) => [...list.filter((x) => x.id !== item.id), item].slice(-MAX_TOASTS));
  }, []);

  useEffect(() => subscribeToasts(addToast), [addToast]);

  useNuiEvent('open', (m) => {
    if (!m.session) return;
    const next = normalizeSession(m.session);
    const target: UiKind = m.ui ?? next.ui;
    setSession(next);
    setUi(target);
    if (m.screen && screensFor(target, next).some((s) => s.key === m.screen)) {
      setScreens((prev) => ({ ...prev, [target]: { key: m.screen as ScreenKey, params: {} } }));
    }
  });
  useNuiEvent('close', () => setUi(null));
  useNuiEvent('session', (m) => {
    if (m.session) setSession(normalizeSession(m.session));
  });
  useNuiEvent('notify', (m) => {
    if (m.notification) pushNotification({ ...m.notification, id: m.notification.id ?? `lua-${Date.now()}` });
  });
  useNuiEvent('hud', (m) => setHud(m.hud ? normalizeHud(m.hud) : null));
  useNuiEvent('result', (m) => {
    setResult(m.result ? normalizeResult(m.result) : null);
    setResultSeq((n) => n + 1);
  });
  useNuiEvent('overlay', (m) => setOverlay(m.overlay ?? null));
  useNuiEvent('theme', (m) => {
    setHudTheme(m.theme ?? null);
    if (m.locale && typeof m.locale === 'object') setBootLocale(m.locale);
  });
  usePush<{ debug?: unknown } | null>('test', (data) => {
    if (data && typeof data === 'object' && 'debug' in data) setDebug(data.debug ?? null);
  });

  // ── Tablet controls ────────────────────────────────────────────────────────
  const close = useCallback(() => {
    setUi(null);
    void fetchNui('close', {});
  }, []);

  const switchUi = useCallback(async (target: UiKind) => {
    setSwitching(true);
    const res = await fetchNui<Session>('switchUi', { ui: target });
    setSwitching(false);
    if (res.ok && res.data) {
      setSession(normalizeSession(res.data));
      setUi(target);
      return true;
    }
    toast('error', t(res.error || 'err.internal'));
    return false;
  }, []);

  const dismissResult = useCallback(() => setResult(null), []);

  const refreshSession = useCallback(async () => {
    if (!ui) return;
    const res = await request<Session>('getSession', { ui });
    if (res.ok && res.data) setSession(normalizeSession(res.data));
  }, [ui]);

  // Escape closes the top dialog first, then the UI.
  useEffect(() => {
    if (!ui) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || e.repeat) return;
      e.preventDefault();
      if (!closeTopLayer()) close();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [ui, close]);

  // ── Navigation ─────────────────────────────────────────────────────────────
  const available = useMemo(() => (ui ? screensFor(ui, session).map((s) => s.key) : []), [ui, session]);
  const current = ui ? screens[ui] : null;
  const screenKey: ScreenKey = current && available.includes(current.key) ? current.key : (available[0] ?? 'home');

  const navigate = useCallback(
    (key: ScreenKey, params?: ScreenParams) => {
      if (!ui) return;
      if (!available.includes(key)) {
        console.warn(`[crimson-police:ui] navigate('${key}') ignored: not a screen of the ${ui} UI`);
        return;
      }
      setScreens((prev) => ({ ...prev, [ui]: { key, params: params ?? {} } }));
    },
    [ui, available],
  );

  const nav: NavigationValue = useMemo(
    () => ({ screen: screenKey, params: current && current.key === screenKey ? current.params : {}, navigate, available }),
    [screenKey, current, navigate, available],
  );

  const sessionValue: SessionContextValue = useMemo(
    () => ({ session, ui, close, switchUi, refreshSession, switching }),
    [session, ui, close, switchUi, refreshSession, switching],
  );

  // ── Theme for everything outside the tablet (HUD, result, toasts, overlays) ──
  const ambientTheme: Theme =
    (ui && session ? session.theme : null) ?? hudTheme ?? (session && session.ui !== 'admin' ? session.theme : null) ?? DEFAULT_THEME;
  useLayoutEffect(() => {
    applyTheme(document.documentElement, ambientTheme);
  }, [ambientTheme]);

  const locale = session?.locale ?? bootLocale ?? null;
  const uiOpen = !!(ui && session);
  // The HUD hides only while the Officer UI is open (its tablet pins the run bar instead). The Supervisor and
  // Admin UIs have no run bar, so the HUD (timer, objectives, off-route countdown) stays on top of them, as does
  // the result card (SPEC Route to the start: the off-route warning shows on the HUD and the tablet).
  const showHud = !!hud && !(uiOpen && ui === 'officer');
  const showColumn = showHud || !!result;

  // Toasts: top-right of the screen, or top-right inside the open tablet / below the admin header.
  const toastStyle = useMemo((): CSSProperties => {
    const { width, height } = viewport;
    if (uiOpen && ui !== 'admin') {
      const s = tabletScale(width, height);
      return {
        top: Math.round((height - TABLET_H * s) / 2 + (15 + 62 + 14) * s),
        right: Math.round((width - TABLET_W * s) / 2 + (15 + 18) * s),
        transform: `scale(${s})`,
      };
    }
    if (uiOpen && ui === 'admin') {
      const z = Math.max(1, Math.min(width / 1920, height / 1080));
      return { top: Math.round(74 * z), right: Math.round(20 * z), transform: z !== 1 ? `scale(${z})` : undefined };
    }
    return { top: Math.round(24 * hudScale), right: Math.round(24 * hudScale), transform: hudScale !== 1 ? `scale(${hudScale})` : undefined };
  }, [viewport, uiOpen, ui, hudScale]);

  return (
    <LocaleProvider locale={locale}>
      <SessionContext.Provider value={sessionValue}>
        <NavigationContext.Provider value={nav}>
          {showColumn ? (
            <HudColumn scale={hudScale} overUi={uiOpen}>
              {showHud && hud ? <Hud hud={hud} /> : null}
              {result ? <ResultScreen key={resultSeq} result={result} onDismiss={dismissResult} /> : null}
            </HudColumn>
          ) : null}

          <DebugOverlay debug={debug} hud={hud} />

          {overlay?.kind === 'fade' ? <FadeOverlay overlay={overlay} /> : null}
          {overlay && (overlay.kind === 'placement' || overlay.kind === 'recording' || overlay.kind === 'testdrive') ? (
            <BuilderOverlay overlay={overlay} />
          ) : null}

          {uiOpen ? ui === 'admin' ? <AdminLayout /> : ui === 'supervisor' ? <SupervisorLayout /> : <OfficerLayout /> : null}

          <Toasts toasts={toasts} style={toastStyle} onDismiss={(id) => setToasts((list) => list.filter((x) => x.id !== id))} />

          {DevPanel ? (
            <Suspense fallback={null}>
              <DevPanel />
            </Suspense>
          ) : null}
        </NavigationContext.Provider>
      </SessionContext.Provider>
    </LocaleProvider>
  );
}
