// Browser dev mode only (App lazy-loads this file when isEnvBrowser(); it never runs in FiveM).
// Fakes the Lua side: opens the three UIs, sends HUD states, results, toasts and overlays.
// URL params for quick checks: ?ui=officer|supervisor|admin &dept=sast|fib|bcso &screen=<key>
//   &hud=progress|offroute|test &result=completed|failed|test|flagged &run=1 &toast=info &bg=night|day|none &dev=0
// Dev tool text is English on purpose: it is never shown to players.
import { lazy, Suspense, useEffect, useRef, useState } from 'react';
import { useNavigation, type ScreenKey } from '../shared/navigation';
import { emitDebug, request } from '../shared/nui';
import type { NotificationKind, Session, UiKind } from '../shared/types';
import { devState, type DevDept } from './devState';
import { buildSession, sampleHud, sampleResult, type SampleHudKind, type SampleResultKind } from './samples';
import './devpanel.css';

const Gallery = lazy(() => import('./Gallery'));

type Backdrop = 'night' | 'day' | 'none';

const TOASTS: Record<NotificationKind, { title?: string; text: string }> = {
  info: { title: 'Unit invite', text: 'Cpl. Maria Lopez (2L-21) invited you to their unit.' },
  success: { title: 'Payout received', text: '$1,040 was paid to your bank account.' },
  warning: { text: 'You are off the route to the start. Get back on it within 30 seconds.' },
  error: { title: 'Mission refused', text: 'Server busy: the Tactical run cap is reached.' },
};

async function openUi(ui: UiKind): Promise<void> {
  const res = await request<Session>('getSession', { ui });
  if (res.ok && res.data) emitDebug('open', { ui, session: res.data });
}

function sendTheme() {
  const s = buildSession('officer');
  emitDebug('theme', { theme: s.theme });
}

export default function DevPanel() {
  const params = useRef(new URLSearchParams(window.location.search)).current;
  const [collapsed, setCollapsed] = useState(params.get('dev') === '0');
  const [dept, setDept] = useState<DevDept>((['sast', 'fib', 'bcso'].includes(params.get('dept') ?? '') ? params.get('dept') : 'sast') as DevDept);
  const [openedUi, setOpenedUi] = useState<UiKind | null>(null);
  const [run, setRun] = useState(params.get('run') === '1');
  const [bg, setBg] = useState<Backdrop>((['night', 'day', 'none'].includes(params.get('bg') ?? '') ? params.get('bg') : 'night') as Backdrop);
  const pendingScreen = useRef<string | null>(params.get('screen'));
  const [gallery, setGallery] = useState(false);
  const nav = useNavigation();

  // Boot: simulate login (department theme), then apply URL params.
  useEffect(() => {
    devState.department = dept;
    devState.runActive = run;
    sendTheme();
    const ui = params.get('ui') as UiKind | null;
    if (ui === 'officer' || ui === 'supervisor' || ui === 'admin') {
      void openUi(ui).then(() => setOpenedUi(ui));
    }
    const hud = params.get('hud') as SampleHudKind | null;
    if (hud) emitDebug('hud', { hud: sampleHud(hud) });
    const result = params.get('result') as SampleResultKind | null;
    if (result) emitDebug('result', { result: sampleResult(result) });
    if (params.get('gallery') === '1') void showGallery();
    const toastKind = params.get('toast') as NotificationKind | null;
    if (toastKind && TOASTS[toastKind]) emitDebug('notify', { notification: { id: `dev-${Date.now()}`, kind: toastKind, duration: 0, ...TOASTS[toastKind] } });
  }, []);

  // ?screen=<key> once that screen is available.
  useEffect(() => {
    const key = pendingScreen.current;
    if (key && nav.available.includes(key as ScreenKey)) {
      pendingScreen.current = null;
      nav.navigate(key as ScreenKey);
    }
  }, [nav]);

  const pickDept = (d: DevDept) => {
    setDept(d);
    devState.department = d;
    sendTheme();
    if (openedUi && openedUi !== 'admin') void openUi(openedUi);
  };

  const open = (ui: UiKind) => {
    setOpenedUi(ui);
    void openUi(ui);
  };

  async function showGallery() {
    await openUi('officer');
    emitDebug('close');
    setOpenedUi(null);
    setGallery(true);
  }

  const toggleRun = () => {
    const next = !run;
    setRun(next);
    devState.runActive = next;
    emitDebug('push', { topic: 'run', data: null });
  };

  const toast = (kind: NotificationKind) =>
    emitDebug('notify', { notification: { id: `dev-${Date.now()}`, kind, duration: kind === 'error' ? 7000 : 5000, ...TOASTS[kind] } });

  return (
    <>
      {bg !== 'none' ? <div className={`dev-backdrop dev-backdrop--${bg}`} aria-hidden /> : null}
      {gallery ? (
        <Suspense fallback={null}>
          <Gallery onClose={() => setGallery(false)} />
        </Suspense>
      ) : null}
      {collapsed ? (
        <button type="button" className="dev-fab" onClick={() => setCollapsed(false)} title="Crimson-Police dev panel">
          DEV
        </button>
      ) : (
        <div className="dev-panel" role="region" aria-label="Dev panel">
          <div className="dev-panel__head">
            <strong>Crimson-Police · dev</strong>
            <button type="button" onClick={() => setCollapsed(true)} aria-label="Collapse">
              ×
            </button>
          </div>

          <div className="dev-panel__group">
            <span>UI</span>
            <button type="button" onClick={() => open('officer')}>Officer</button>
            <button type="button" onClick={() => open('supervisor')}>Supervisor</button>
            <button type="button" onClick={() => open('admin')}>Admin</button>
            <button type="button" onClick={() => { setOpenedUi(null); setGallery(false); emitDebug('close'); }}>Close</button>
            <button type="button" className={gallery ? 'is-on' : ''} onClick={() => (gallery ? setGallery(false) : void showGallery())}>Gallery</button>
          </div>

          <div className="dev-panel__group">
            <span>Dept</span>
            {(['sast', 'fib', 'bcso'] as DevDept[]).map((d) => (
              <button type="button" key={d} className={dept === d ? 'is-on' : ''} onClick={() => pickDept(d)}>
                {d === 'bcso' ? 'BCSO (bad logo)' : d.toUpperCase()}
              </button>
            ))}
          </div>

          <div className="dev-panel__group">
            <span>HUD</span>
            <button type="button" onClick={() => emitDebug('hud', { hud: sampleHud('progress') })}>In progress</button>
            <button type="button" onClick={() => emitDebug('hud', { hud: sampleHud('offroute') })}>Off route</button>
            <button type="button" onClick={() => emitDebug('hud', { hud: sampleHud('test') })}>Test run</button>
            <button type="button" onClick={() => emitDebug('hud', { hud: null })}>Hide</button>
          </div>

          <div className="dev-panel__group">
            <span>Result</span>
            <button type="button" onClick={() => emitDebug('result', { result: sampleResult('completed') })}>Completed</button>
            <button type="button" onClick={() => emitDebug('result', { result: sampleResult('failed') })}>Failed</button>
            <button type="button" onClick={() => emitDebug('result', { result: sampleResult('flagged') })}>Flagged</button>
            <button type="button" onClick={() => emitDebug('result', { result: sampleResult('test') })}>Test</button>
            <button type="button" onClick={() => emitDebug('result', { result: null })}>Hide</button>
          </div>

          <div className="dev-panel__group">
            <span>Toast</span>
            {(['info', 'success', 'warning', 'error'] as NotificationKind[]).map((k) => (
              <button type="button" key={k} onClick={() => toast(k)}>
                {k}
              </button>
            ))}
          </div>

          <div className="dev-panel__group">
            <span>Misc</span>
            <button type="button" className={run ? 'is-on' : ''} onClick={toggleRun}>Run bar</button>
            <button type="button" onClick={() => emitDebug('overlay', { overlay: { kind: 'fade', text: 'Picked up by an NPC unit' } })}>Fade</button>
            <button type="button" onClick={() => emitDebug('overlay', { overlay: null })}>Clear overlay</button>
          </div>

          <div className="dev-panel__group">
            <span>Scene</span>
            {(['night', 'day', 'none'] as Backdrop[]).map((b) => (
              <button type="button" key={b} className={bg === b ? 'is-on' : ''} onClick={() => setBg(b)}>
                {b}
              </button>
            ))}
          </div>
        </div>
      )}
    </>
  );
}
