// HUD test controls (Admin test mode, SPEC "Test controls").

import { useCallback, useEffect, useState } from 'react';
import { Icon, Spinner } from '../shared/components';
import type { IconName } from '../shared/components';
import { cx } from '../shared/cx';
import { usePush } from '../shared/hooks';
import { t } from '../shared/i18n';
import { clientAction } from '../shared/nui';
import { toast } from '../shared/toast';
import type { HudState } from '../shared/types';
import type { TestPush } from '../types/testing';
import './TestControls.css';

export interface TestControlsProps {
    hud: HudState;
}

type Confirmable = 'complete' | 'fail' | 'end';

interface Btn {
    key: string;
    icon: IconName;
    label: string;
    hint?: string;
    disabled?: boolean;
    active?: boolean;
    tone?: 'danger' | 'success';
    onClick: () => void;
}

export default function TestControls({ hud }: TestControlsProps) {
    const [focused, setFocused] = useState(false);
    const [key, setKey] = useState('F9');
    const [debugOn, setDebugOn] = useState(false);
    const [allowTeleport, setAllowTeleport] = useState(true);
    const [debugOverlay, setDebugOverlay] = useState(true);
    const [busy, setBusy] = useState<string | null>(null);
    const [confirm, setConfirm] = useState<Confirmable | null>(null);

    usePush<TestPush | null>('test', d => {
        if (!d || typeof d !== 'object') return;
        if (typeof d.focused === 'boolean') setFocused(d.focused);
        if (typeof d.key === 'string' && d.key) setKey(d.key);
        if (typeof d.debugOn === 'boolean') setDebugOn(d.debugOn);
        if (typeof d.allowTeleport === 'boolean') setAllowTeleport(d.allowTeleport);
        if (typeof d.debugOverlay === 'boolean') setDebugOverlay(d.debugOverlay);
        if (d.debug === false || d.debug === null) setDebugOn(false);
    });

    const release = useCallback(() => {
        setConfirm(null);
        setFocused(false);
        void clientAction('testPanel', { open: false });
    }, []);

    // While the panel has focus, F9 / Escape give the game back its input (a pending confirm closes first).
    useEffect(() => {
        if (!focused) return;
        const onKey = (e: KeyboardEvent) => {
            if (e.repeat) return;
            const k = e.key.toUpperCase();
            if (e.key === 'Escape' || k === key.toUpperCase()) {
                e.preventDefault();
                if (e.key === 'Escape' && confirm) setConfirm(null);
                else release();
            }
        };
        window.addEventListener('keydown', onKey);
        return () => window.removeEventListener('keydown', onKey);
    }, [focused, key, confirm, release]);

    const call = async (id: string, name: string, payload: unknown, okKey?: string) => {
        setBusy(id);
        const res = await clientAction<{ debug?: boolean }>(name, payload);
        setBusy(null);
        if (!res.ok) {
            toast('error', t(res.error || 'err.internal'));
            return false;
        }
        if (name === 'toggleDebug') setDebugOn(!!res.data?.debug);
        if (okKey) toast('success', t(okKey));
        return true;
    };
    const control = (c: string, okKey?: string) => call(c, 'testControl', { control: c }, okKey);

    const inObjectives = hud.phase === 'objectives';
    const paused = !!hud.timer?.paused;
    const ended = hud.phase === 'ended';

    const rows: Btn[][] = [
        [
            {
                key: 'skip',
                icon: 'chevronRight',
                label: t('test.control.skip_short'),
                hint: t('test.control.skip'),
                disabled: !inObjectives,
                onClick: () => void control('skip', 'test.ui.skipped'),
            },
            {
                key: 'restart',
                icon: 'refresh',
                label: t('test.control.restart_short'),
                hint: t('test.control.restart'),
                disabled: !inObjectives,
                onClick: () => void control('restart', 'test.ui.restarted'),
            },
            {
                key: paused ? 'resume' : 'pause',
                icon: paused ? 'play' : 'pause',
                label: t(paused ? 'test.control.resume_short' : 'test.control.pause_short'),
                hint: t(paused ? 'test.control.resume' : 'test.control.pause'),
                disabled: !inObjectives || !hud.timer,
                active: paused,
                onClick: () => void control(paused ? 'resume' : 'pause'),
            },
        ],
        [
            {
                key: 'tp_start',
                icon: 'mapPin',
                label: t('test.control.teleport_start_short'),
                hint: t(allowTeleport ? 'test.control.teleport_start' : 'err.test_teleport_disabled'),
                disabled: !allowTeleport,
                onClick: () => void call('tp_start', 'teleport', { target: 'start' }),
            },
            {
                key: 'tp_obj',
                icon: 'target',
                label: t('test.control.teleport_objective_short'),
                hint: t(allowTeleport ? 'test.control.teleport_objective' : 'err.test_teleport_disabled'),
                disabled: !allowTeleport || !inObjectives,
                onClick: () => void call('tp_obj', 'teleport', { target: 'objective' }),
            },
            {
                key: 'debug',
                icon: 'eye',
                label: t('test.control.debug_short'),
                hint: t(debugOverlay ? 'test.control.debug' : 'err.test_debug_disabled'),
                disabled: !debugOverlay,
                active: debugOn,
                onClick: () => void call('debug', 'toggleDebug', { enabled: !debugOn }),
            },
        ],
        [
            {
                key: 'complete',
                icon: 'checkCircle',
                label: t('test.control.complete_short'),
                hint: t('test.control.complete'),
                tone: 'success',
                onClick: () => setConfirm('complete'),
            },
            {
                key: 'fail',
                icon: 'xCircle',
                label: t('test.control.fail_short'),
                hint: t('test.control.fail'),
                tone: 'danger',
                onClick: () => setConfirm('fail'),
            },
            { key: 'end', icon: 'x', label: t('test.control.end'), tone: 'danger', onClick: () => setConfirm('end') },
        ],
    ];

    if (ended) return null;

    return (
        <div className={cx('testing-hud', focused ? 'is-focused' : 'is-idle')} aria-label={t('test.ui.controls')}>
            <div className="testing-hud__head">
                <span className="testing-hud__title">
                    <Icon name="tool" size={13} />
                    {t('test.ui.controls')}
                </span>
                {focused ? (
                    <button type="button" className="testing-hud__release" onClick={release}>
                        {t('test.ui.panel_release', { key })}
                    </button>
                ) : (
                    <span className="testing-hud__hint">
                        <kbd className="testing-hud__kbd">{key}</kbd>
                        {t('test.ui.panel_hint')}
                    </span>
                )}
            </div>

            {confirm ? (
                <div
                    className={cx('testing-hud__confirm', confirm === 'complete' ? 'is-success' : 'is-danger')}
                    role="alertdialog"
                >
                    <span className="testing-hud__confirm-text">{t(`test.ui.confirm_${confirm}_short`)}</span>
                    <div className="testing-hud__confirm-actions">
                        <button
                            type="button"
                            className="testing-hud__btn"
                            onClick={() => setConfirm(null)}
                            disabled={!focused}
                        >
                            {t('common.cancel')}
                        </button>
                        <button
                            type="button"
                            className={cx(
                                'testing-hud__btn',
                                'is-solid',
                                confirm === 'complete' ? 'is-success' : 'is-danger',
                            )}
                            disabled={!focused || busy === confirm}
                            onClick={async () => {
                                const c = confirm;
                                await control(c);
                                setConfirm(null);
                            }}
                        >
                            {busy === confirm ? <Spinner size={12} /> : null}
                            {t(`test.control.${confirm}`)}
                        </button>
                    </div>
                </div>
            ) : (
                <div className="testing-hud__grid" role="group">
                    {rows.flat().map(b => (
                        <button
                            key={b.key}
                            type="button"
                            className={cx('testing-hud__btn', b.active && 'is-active', b.tone && `is-${b.tone}`)}
                            disabled={!focused || b.disabled || busy !== null}
                            aria-pressed={b.active || undefined}
                            onClick={b.onClick}
                            title={b.hint ?? b.label}
                        >
                            {busy === b.key ? <Spinner size={12} /> : <Icon name={b.icon} size={14} />}
                            <span className="testing-hud__btn-label">{b.label}</span>
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
}
