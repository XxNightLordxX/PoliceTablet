// NUI root. Owns every Lua-driven state (session, open UI, HUD, result, toasts, overlay, HUD theme) and renders the
// right layout. Nothing renders while nothing is active, and the page itself stays transparent (the game is drawn
// behind it).

import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useState, type CSSProperties } from 'react';
import { AdminLayout } from './layouts/AdminLayout';
import { OfficerLayout } from './layouts/OfficerLayout';
import { SupervisorLayout } from './layouts/SupervisorLayout';
import { defaultScreen, landingScreen, screensFor } from './layouts/screens';
import { TABLET_H, TABLET_W, tabletScale } from './layouts/TabletFrame';
import BuilderOverlay from './hud/BuilderOverlay';
import DebugOverlay from './hud/DebugOverlay';
import { FadeOverlay } from './hud/FadeOverlay';
import { Hud } from './hud/Hud';
import { HudColumn, MotionPref } from './hud/HudColumn';
import { ResultScreen } from './hud/ResultScreen';
import { QuietBoundary, Toasts } from './shared/components';
import { closeTopLayer, useHudScale, useKeyRelease, usePush, useViewport } from './shared/hooks';
import { LocaleProvider, t } from './shared/i18n';
import { NavigationContext, type NavigationValue, type ScreenKey, type ScreenParams } from './shared/navigation';
import { clientAction, fetchNui, isEnvBrowser, request, setTabletShown, useNuiEvent } from './shared/nui';
import { openScreenFor } from './shared/openOn';
import { OptionsProvider, useOption } from './shared/options';
import { SessionContext, type SessionContextValue } from './shared/session';
import { applyAppearance, DEFAULT_THEME, mergeAppearance } from './shared/theme';
import { normalizeHud, normalizeResult, normalizeSession } from './shared/data';
import { pushNotification, setToastTime, subscribeToasts, toast, toastMs } from './shared/toast';
import type {
    HudState,
    Notification,
    OfficerOptionValue,
    Overlay,
    Prefs,
    RunResult,
    Session,
    Theme,
    UiKind,
} from './shared/types';

// Browser dev mode only (never loaded inside FiveM).
const DevPanel = isEnvBrowser() ? lazy(() => import('./mocks/DevPanel')) : null;

const MAX_TOASTS = 5;
let readySent = false;

// The officer's look from the theme message (step O5): his prefs and the options hudLook and textSize.
interface ThemeLook {
    prefs: Partial<Prefs> | null;
    options: Record<string, OfficerOptionValue> | null;
}

// The theme of everything outside the tablet (HUD, result card, toasts, overlays) on the page root. With the officer
// option hudLook on, his tablet look (appearance and accent) goes on top of it; the open Admin UI keeps its own theme.
function AmbientLook({
    theme,
    prefs,
    accents,
    adminOpen,
}: {
    theme: Theme;
    prefs: Partial<Prefs> | null;
    accents: { colour: string }[] | null;
    adminOpen: boolean;
}): null {
    const on = useOption('hudLook') === true && !adminOpen && !!prefs;
    const appearance = on ? (prefs?.appearance ?? 'department') : 'department';
    const accent = on ? (prefs?.accent ?? null) : null;
    const look = useMemo(
        () => (on ? mergeAppearance(theme, appearance, accent, accents) : theme),
        [on, theme, appearance, accent, accents],
    );
    useLayoutEffect(() => {
        applyAppearance(document.documentElement, look, appearance);
    }, [look, appearance]);
    return null;
}

// The officer option toastTime (step O6): how long the toasts that carry no time of their own stay.
function ToastTimePref(): null {
    const time = useOption('toastTime');
    useLayoutEffect(() => setToastTime(time), [time]);
    return null;
}

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
    // the officer's look as the latest theme message gave it, and whether a session came after it (then it wins)
    const [themeLook, setThemeLook] = useState<ThemeLook | null>(null);
    const [lookFromSession, setLookFromSession] = useState(false);
    const [bootLocale, setBootLocale] = useState<Record<string, string> | null>(null);
    const [debug, setDebug] = useState<unknown>(null);
    const [screens, setScreens] = useState<ScreenState>(initialScreens);
    const [switching, setSwitching] = useState(false);
    const [openSeq, setOpenSeq] = useState(0);
    const hudScale = useHudScale();
    const viewport = useViewport();

    // ---- LUA → NUI ---------------------------------------------------------
    useEffect(() => {
        if (readySent) return;
        readySent = true;
        // acks: every 'open' with a seq is confirmed with 'opened' once the UI is on screen
        void fetchNui('ready', { acks: true });
    }, []);

    const addToast = useCallback((n: Notification) => {
        // a bell-only toast (quietRun during a run) is listed by the bell (NotificationBell) and not shown
        if (!n || !n.text || n.bellOnly) return;
        const kind = n.kind ?? 'info';
        const item: Notification = {
            ...n,
            kind,
            duration: typeof n.duration === 'number' ? n.duration : toastMs(kind),
        };
        setToasts(list => [...list.filter(x => x.id !== item.id), item].slice(-MAX_TOASTS));
    }, []);

    useEffect(() => subscribeToasts(addToast), [addToast]);

    useNuiEvent('open', m => {
        let next: Session;
        try {
            if (!m.session) throw new Error('open without a session');
            next = normalizeSession(m.session);
        } catch (e) {
            // Lua already took the NUI focus: hand it back rather than keep it on a page that shows nothing.
            console.error('[crimson-police:ui] open failed', e);
            setTabletShown(false);
            setUi(null);
            void fetchNui('close', {});
            return;
        }
        const target: UiKind = m.ui ?? next.ui;
        setSession(next);
        setTabletShown(true);
        setUi(target);
        if (typeof m.seq === 'number') setOpenSeq(m.seq);
        // Lua names a screen (the Dispatch key, a call just now); else the officer option openOn picks one, or none
        const screen = m.screen ?? openScreenFor(target, next);
        if (screen && screensFor(target, next).some(s => s.key === screen)) {
            setScreens(prev => ({ ...prev, [target]: { key: screen as ScreenKey, params: {} } }));
        }
    });
    useNuiEvent('close', () => {
        setTabletShown(false);
        setUi(null);
    });
    useNuiEvent('session', m => {
        if (m.session) setSession(normalizeSession(m.session));
    });
    useNuiEvent('notify', m => {
        if (m.notification) pushNotification({ ...m.notification, id: m.notification.id ?? `lua-${Date.now()}` });
    });
    useNuiEvent('hud', m => setHud(prev => (m.hud ? normalizeHud(m.hud, prev) : null)));
    useNuiEvent('result', m => {
        setResult(m.result ? normalizeResult(m.result) : null);
        setResultSeq(n => n + 1);
    });
    // Lua repeats the builder overlay every 150 ms while a tool is open: an identical one keeps the current state.
    useNuiEvent('overlay', m => {
        const next = m.overlay ?? null;
        setOverlay(prev => (prev && next && JSON.stringify(prev) === JSON.stringify(next) ? prev : next));
    });
    useNuiEvent('theme', m => {
        setHudTheme(m.theme ?? null);
        setThemeLook({ prefs: m.prefs ?? null, options: m.options ?? null });
        setLookFromSession(false);
        if (m.locale && typeof m.locale === 'object') setBootLocale(m.locale);
    });
    useNuiEvent('locale', m => {
        if (!m.locale || typeof m.locale !== 'object') return;
        setBootLocale(m.locale);
        setSession(prev => (prev ? { ...prev, locale: m.locale } : prev));
    });
    usePush<{ debug?: unknown } | null>('test', data => {
        if (data && typeof data === 'object' && 'debug' in data) setDebug(data.debug ?? null);
    });

    // ---- TABLET CONTROLS ---------------------------------------------------
    const close = useCallback(() => {
        setTabletShown(false);
        setUi(null);
        void fetchNui('close', {});
    }, []);

    const switchUi = useCallback(async (target: UiKind) => {
        setSwitching(true);
        const res = await fetchNui<Session>('switchUi', { ui: target });
        setSwitching(false);
        if (res.ok && res.data) {
            setSession(normalizeSession(res.data));
            setTabletShown(true);
            setUi(target);
            return true;
        }
        toast('error', t(res.error || 'err.internal'));
        return false;
    }, []);

    const dismissResult = useCallback(() => setResult(null), []);

    // A crashed HUD or test overlay may be the panel that held the NUI focus (test controls, invitations).
    const releaseTestFocus = useCallback(() => void clientAction('testPanel', { open: false }), []);

    const refreshSession = useCallback(async () => {
        if (!ui) return;
        const res = await request<Session>('getSession', { ui });
        if (res.ok && res.data) setSession(normalizeSession(res.data));
    }, [ui]);

    // Escape closes the top dialog first, then the UI (on its key-up: useKeyRelease).
    useKeyRelease(
        !!ui,
        e => e.key === 'Escape',
        () => {
            if (!closeTopLayer()) close();
        },
    );

    // ---- NAVIGATION --------------------------------------------------------
    const available = useMemo(() => (ui ? screensFor(ui, session).map(s => s.key) : []), [ui, session]);
    const current = ui ? screens[ui] : null;
    const screenKey: ScreenKey =
        current && available.includes(current.key) ? current.key : ui ? landingScreen(ui, session, available) : 'home';

    const navigate = useCallback(
        (key: ScreenKey, params?: ScreenParams) => {
            if (!ui) return;
            if (!available.includes(key)) {
                console.warn(`[crimson-police:ui] navigate('${key}') ignored: not a screen of the ${ui} UI`);
                return;
            }
            setScreens(prev => ({ ...prev, [ui]: { key, params: params ?? {} } }));
        },
        [ui, available],
    );

    const nav: NavigationValue = useMemo(
        () => ({
            screen: screenKey,
            params: current && current.key === screenKey ? current.params : {},
            navigate,
            available,
        }),
        [screenKey, current, navigate, available],
    );

    const sessionValue: SessionContextValue = useMemo(
        () => ({ session, ui, close, switchUi, refreshSession, switching }),
        [session, ui, close, switchUi, refreshSession, switching],
    );

    // ---- THEME FOR EVERYTHING OUTSIDE THE TABLET (HUD, result, toasts, overlays) ----
    const ambientTheme: Theme =
        (ui && session ? session.theme : null) ??
        hudTheme ??
        (session && session.ui !== 'admin' ? session.theme : null) ??
        DEFAULT_THEME;
    // a new officer or supervisor session is newer than the last theme message (an Admin UI session has no look)
    useEffect(() => {
        if (session && session.ui !== 'admin') setLookFromSession(true);
    }, [session]);
    const sessionLook = lookFromSession && !!session && session.ui !== 'admin';
    const ambientPrefs: Partial<Prefs> | null = sessionLook ? (session?.prefs ?? null) : (themeLook?.prefs ?? null);
    const ambientAccents = sessionLook ? (session?.config?.profile?.accents ?? null) : null;
    const ambientOptions = sessionLook ? null : (themeLook?.options ?? null);

    const locale = session?.locale ?? bootLocale ?? null;
    const uiOpen = !!(ui && session);

    // The UI of that 'open' is on screen (a crashed layout closed it first): without this Lua releases the focus.
    useEffect(() => {
        if (uiOpen && openSeq > 0) void fetchNui('opened', { seq: openSeq });
    }, [uiOpen, openSeq]);

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
            return {
                top: Math.round(74 * z),
                right: Math.round(20 * z),
                transform: z !== 1 ? `scale(${z})` : undefined,
            };
        }
        return {
            top: Math.round(24 * hudScale),
            right: Math.round(24 * hudScale),
            transform: hudScale !== 1 ? `scale(${hudScale})` : undefined,
        };
    }, [viewport, uiOpen, ui, hudScale]);

    // The layout element only changes with the UI kind: App-level state that the tablet does not read (hud, debug,
    // toasts, result, overlay) no longer re-renders the open tablet. Session, navigation and locale still reach it
    // through their contexts (every layout reads useSession / useNavigation).
    const layout = useMemo(
        () => (ui === 'admin' ? <AdminLayout /> : ui === 'supervisor' ? <SupervisorLayout /> : <OfficerLayout />),
        [ui],
    );

    return (
        <LocaleProvider locale={locale}>
            <SessionContext.Provider value={sessionValue}>
                <OptionsProvider session={session} ambient={ambientOptions}>
                    <MotionPref />
                    <ToastTimePref />
                    <AmbientLook
                        theme={ambientTheme}
                        prefs={ambientPrefs}
                        accents={ambientAccents}
                        adminOpen={uiOpen && ui === 'admin'}
                    />
                    <NavigationContext.Provider value={nav}>
                        {showColumn ? (
                            <QuietBoundary
                                name="hud column"
                                resetKey={`${resultSeq}:${hud?.runId ?? ''}`}
                                onError={releaseTestFocus}
                            >
                                <HudColumn scale={hudScale} overUi={uiOpen}>
                                    {showHud && hud ? (
                                        <QuietBoundary name="hud" resetKey={hud.runId} onError={releaseTestFocus}>
                                            <Hud hud={hud} />
                                        </QuietBoundary>
                                    ) : null}
                                    {result ? (
                                        <QuietBoundary name="result card" resetKey={resultSeq}>
                                            <ResultScreen key={resultSeq} result={result} onDismiss={dismissResult} />
                                        </QuietBoundary>
                                    ) : null}
                                </HudColumn>
                            </QuietBoundary>
                        ) : null}

                        <QuietBoundary name="debug overlay" resetKey={debug} onError={releaseTestFocus}>
                            <DebugOverlay debug={debug} hud={hud} />
                        </QuietBoundary>

                        <QuietBoundary name="overlay" resetKey={overlay}>
                            {overlay?.kind === 'fade' ? <FadeOverlay overlay={overlay} /> : null}
                            {overlay &&
                            (overlay.kind === 'placement' ||
                                overlay.kind === 'recording' ||
                                overlay.kind === 'testdrive') ? (
                                <BuilderOverlay overlay={overlay} />
                            ) : null}
                        </QuietBoundary>

                        {uiOpen ? (
                            // A crashed layout shell (outside ScreenHost's per-screen boundary) closes the tablet, so
                            // Lua releases the NUI focus instead of holding it on an empty page.
                            <QuietBoundary name={`${ui} layout`} resetKey={`${ui}:${openSeq}`} onError={close}>
                                {layout}
                            </QuietBoundary>
                        ) : null}

                        <QuietBoundary name="toasts" resetKey={toasts}>
                            <Toasts
                                toasts={toasts}
                                style={toastStyle}
                                onDismiss={id => setToasts(list => list.filter(x => x.id !== id))}
                            />
                        </QuietBoundary>

                        {DevPanel ? (
                            <Suspense fallback={null}>
                                <DevPanel />
                            </Suspense>
                        ) : null}
                    </NavigationContext.Provider>
                </OptionsProvider>
            </SessionContext.Provider>
        </LocaleProvider>
    );
}
