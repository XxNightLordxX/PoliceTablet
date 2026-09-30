// Test-mode overlay layer: the debug overlay (live NPC/entity counts against the caps) and the test
// invitation prompt.

import { useCallback, useEffect, useState } from 'react';
import { Button, Countdown, Icon } from '../shared/components';
import { cx } from '../shared/cx';
import { formatDuration } from '../shared/format';
import { useHudScale, usePush } from '../shared/hooks';
import { t } from '../shared/i18n';
import { action, clientAction } from '../shared/nui';
import { toast } from '../shared/toast';
import type { HudState } from '../shared/types';
import { asList, type TestDebugData, type TestInvite, type TestPush } from '../types/testing';
import './DebugOverlay.css';

export interface DebugOverlayProps {
    debug: unknown;
    hud: HudState | null;
}

function isDebug(v: unknown): v is TestDebugData {
    return (
        !!v &&
        typeof v === 'object' &&
        'counts' in (v as Record<string, unknown>) &&
        typeof (v as TestDebugData).counts === 'object'
    );
}

function Meter({ label, value, max }: { label: string; value: number; max: number }) {
    const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
    const tone = value >= max ? 'is-danger' : pct >= 80 ? 'is-warning' : 'is-ok';
    return (
        <div className={cx('testing-dbg__meter', tone)}>
            <div className="testing-dbg__meter-head">
                <span>{label}</span>
                <span className="cp-num">
                    <b>{value}</b> / {max}
                </span>
            </div>
            <div className="testing-dbg__meter-track">
                <div style={{ width: `${pct}%` }} />
            </div>
        </div>
    );
}

function DebugPanel({ d, scale }: { d: TestDebugData; scale: number }) {
    const c = d.counts;
    const obj = d.objective;
    return (
        <aside
            className="testing-dbg"
            style={{ transform: scale !== 1 ? `scale(${scale})` : undefined }}
            aria-label={t('test.debug.title')}
        >
            <div className="testing-dbg__head">
                <span className="testing-dbg__title">
                    <Icon name="eye" size={13} />
                    {t('test.debug.title')}
                </span>
                <span className="testing-dbg__state">
                    {t(d.state === 'in_progress' ? 'test.ui.state_in_progress' : 'test.ui.state_accepted')}
                </span>
            </div>
            <div className="testing-dbg__mission">
                <strong>{d.missionLabel}</strong>
                <span>{t('test.ui.location_short', { n: d.locationIndex, label: d.locationLabel })}</span>
            </div>
            <div className="testing-dbg__objective">
                {obj ? (
                    <>
                        <span className="testing-dbg__obj-index cp-num">
                            {t('test.debug.objective_index', { index: obj.index, total: obj.total })}
                        </span>
                        <span className="testing-dbg__obj-label">{obj.label}</span>
                        <span className="testing-dbg__obj-block">{obj.block}</span>
                    </>
                ) : (
                    <span className="testing-dbg__obj-label">{t('test.debug.no_objective')}</span>
                )}
            </div>
            <Meter label={t('test.debug.armed_alive')} value={c.armedAlive} max={c.maxArmedAlive} />
            <Meter label={t('test.debug.entities')} value={c.entities} max={c.maxEntities} />
            <div className="testing-dbg__grid cp-num">
                <span>{t('test.debug.peds')}</span>
                <b>{c.peds}</b>
                <span>{t('test.debug.vehicles')}</span>
                <b>{c.vehicles}</b>
                <span>{t('test.debug.objects')}</span>
                <b>{c.objects}</b>
                <span>{t('test.debug.dead')}</span>
                <b>{c.dead}</b>
            </div>
            <div className="testing-dbg__legend">
                <span className="testing-dbg__key is-point" />
                <span>{t('test.debug.spawn_points', { n: d.spawnPoints })}</span>
                <span className="testing-dbg__key is-route" />
                <span>{t('test.debug.waypoints', { n: d.waypoints })}</span>
                <span className="testing-dbg__key is-zone" />
                <span>{t('test.debug.zones', { n: d.zones })}</span>
                <span className="testing-dbg__key is-start" />
                <span>{t('test.debug.start_radius', { r: Math.round(d.startRadius || 0) })}</span>
            </div>
            <div className="testing-dbg__foot">
                <span>
                    {t('test.debug.host')} <b>{d.hostName || (d.host ? `#${d.host}` : '—')}</b>
                </span>
                <span className="cp-num">
                    {d.remaining !== false ? (
                        <>
                            {d.paused ? <Icon name="pause" size={11} /> : <Icon name="clock" size={11} />}{' '}
                            {formatDuration(d.remaining)}
                        </>
                    ) : (
                        '—'
                    )}
                </span>
            </div>
        </aside>
    );
}

function InvitePrompt({ invites, onClose }: { invites: TestInvite[]; onClose: () => void }) {
    const [busy, setBusy] = useState<string | null>(null);
    const [list, setList] = useState(invites);
    useEffect(() => setList(invites), [invites]);

    const respond = async (inv: TestInvite, accepted: boolean) => {
        setBusy(inv.inviteId);
        const res = await action('server:testRespond', { inviteId: inv.inviteId, accepted });
        setBusy(null);
        if (!res.ok) {
            toast('error', t(res.error || 'err.internal'));
            return;
        }
        toast(accepted ? 'success' : 'info', t(accepted ? 'test.ui.invite_accepted' : 'test.ui.invite_declined'));
        const rest = list.filter(i => i.inviteId !== inv.inviteId);
        setList(rest);
        if (!rest.length || accepted) onClose();
    };

    return (
        <div className="testing-prompt" role="dialog" aria-modal="true" aria-label={t('test.ui.invites_title')}>
            <div className="testing-prompt__card">
                <div className="testing-prompt__head">
                    <span className="testing-prompt__icon" aria-hidden>
                        <Icon name="flask" size={18} />
                    </span>
                    <div>
                        <div className="testing-prompt__title">{t('test.ui.invites_title')}</div>
                        <div className="testing-prompt__sub">{t('test.ui.prompt_sub')}</div>
                    </div>
                </div>
                <ul className="testing-prompt__list">
                    {list.map(inv => (
                        <li key={inv.inviteId} className="testing-prompt__row">
                            <div className="testing-prompt__text">
                                <strong>{inv.missionLabel}</strong>
                                <span>
                                    {t('test.ui.prompt_from', { from: inv.from })} ·{' '}
                                    <Countdown seconds={inv.expiresIn} warnBelow={30} dangerBelow={10} />
                                </span>
                            </div>
                            <Button
                                size="sm"
                                variant="ghost"
                                disabled={busy === inv.inviteId}
                                onClick={() => respond(inv, false)}
                            >
                                {t('test.ui.decline')}
                            </Button>
                            <Button
                                size="sm"
                                variant="primary"
                                icon="check"
                                loading={busy === inv.inviteId}
                                onClick={() => respond(inv, true)}
                            >
                                {t('test.ui.accept')}
                            </Button>
                        </li>
                    ))}
                </ul>
                <div className="testing-prompt__foot">
                    <span className="testing-prompt__hint">{t('test.ui.prompt_hint')}</span>
                    <Button size="sm" variant="secondary" onClick={onClose}>
                        {t('common.close')}
                    </Button>
                </div>
            </div>
        </div>
    );
}

export default function DebugOverlay({ debug, hud }: DebugOverlayProps) {
    const scale = useHudScale();
    const [prompt, setPrompt] = useState<TestInvite[] | null>(null);
    const [focused, setFocused] = useState(false);

    usePush<TestPush | null>('test', d => {
        if (!d || typeof d !== 'object') return;
        if (typeof d.focused === 'boolean') setFocused(d.focused);
        if (!('prompt' in d)) return;
        const p = d.prompt;
        setPrompt(p && typeof p === 'object' ? asList(p.invites) : null);
    });

    // Safety net: the Lua client holds NUI focus for the HUD test panel but the panel is not on screen
    // (no HUD with testControls): Escape still gives the game its input back.
    const panelShown = !!hud && hud.testControls === true;
    useEffect(() => {
        if (!focused || prompt || panelShown) return;
        const onKey = (e: KeyboardEvent) => {
            if (e.key === 'Escape' && !e.repeat) {
                e.preventDefault();
                setFocused(false);
                void clientAction('testPanel', { open: false });
            }
        };
        window.addEventListener('keydown', onKey);
        return () => window.removeEventListener('keydown', onKey);
    }, [focused, prompt, panelShown]);

    const closePrompt = useCallback(() => {
        setPrompt(null);
        void clientAction('testPanel', { open: false });
    }, []);

    useEffect(() => {
        if (!prompt) return;
        const onKey = (e: KeyboardEvent) => {
            if (e.key === 'Escape' && !e.repeat) {
                e.preventDefault();
                closePrompt();
            }
        };
        window.addEventListener('keydown', onKey);
        return () => window.removeEventListener('keydown', onKey);
    }, [prompt, closePrompt]);

    const fallback = hud ? (hud as HudState & { debug?: unknown }).debug : undefined;
    const data = isDebug(debug) ? debug : isDebug(fallback) ? fallback : null;
    if (!data && !prompt) return null;
    return (
        <>
            {data ? <DebugPanel d={data} scale={scale} /> : null}
            {prompt && prompt.length ? <InvitePrompt invites={prompt} onClose={closePrompt} /> : null}
        </>
    );
}
