// The header bell: the last 20 Crimson-Police toasts of this session (Lua and UI toasts alike), newest first, with
// the number that arrived since the list was last opened.

import { useEffect, useRef, useState } from 'react';
import { Icon, IconButton } from '../shared/components';
import { cx } from '../shared/cx';
import { useEscapeLayer } from '../shared/hooks';
import { t } from '../shared/i18n';
import { subscribeToasts } from '../shared/toast';
import type { Notification } from '../shared/types';
import './access.css';

export const BELL_MAX = 20;

export interface BellEntry {
    id: string;
    kind: Notification['kind'];
    title: string | null;
    text: string;
    at: number;
}

// Kept for the whole NUI session (it survives closing the tablet), fed from the toast bus from the first import.
const history: BellEntry[] = [];
let unseen = 0;
let seq = 0;
const listeners = new Set<() => void>();

export function recordToast(n: Notification, at: number = Date.now()): void {
    if (!n || !n.text) return;
    history.unshift({ id: `bell-${++seq}`, kind: n.kind ?? 'info', title: n.title ?? null, text: n.text, at });
    if (history.length > BELL_MAX) history.length = BELL_MAX;
    unseen = Math.min(BELL_MAX, unseen + 1);
    listeners.forEach(fn => fn());
}

export function bellHistory(): BellEntry[] {
    return history.slice();
}

export function bellUnseen(): number {
    return unseen;
}

function markSeen(): void {
    unseen = 0;
    listeners.forEach(fn => fn());
}

subscribeToasts(n => recordToast(n));

function timeOf(at: number): string {
    const d = new Date(at);
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

const KIND_ICON = { info: 'info', success: 'checkCircle', warning: 'alert', error: 'xCircle' } as const;

export function NotificationBell() {
    const [, setTick] = useState(0);
    const [open, setOpen] = useState(false);
    const box = useRef<HTMLDivElement>(null);

    useEffect(() => {
        const fn = () => setTick(n => n + 1);
        listeners.add(fn);
        return () => {
            listeners.delete(fn);
        };
    }, []);
    useEffect(() => {
        if (!open) return;
        markSeen();
        const onDown = (e: MouseEvent) => {
            if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
        };
        window.addEventListener('mousedown', onDown);
        return () => window.removeEventListener('mousedown', onDown);
    }, [open]);
    useEscapeLayer(open, () => setOpen(false));

    const list = bellHistory();
    const count = open ? 0 : bellUnseen();
    return (
        <div className="cp-bell" ref={box}>
            <IconButton
                icon="bell"
                label={count > 0 ? t('access.bell.label_new', { n: count }) : t('access.bell.label')}
                className={cx('cp-bell__button', open && 'is-open')}
                aria-expanded={open}
                onClick={() => setOpen(v => !v)}
            />
            {count > 0 ? <span className="cp-bell__count">{count > 9 ? '9+' : count}</span> : null}
            {open ? (
                <div className="cp-bell__panel" role="dialog" aria-label={t('access.bell.title')}>
                    <div className="cp-bell__head">
                        <strong>{t('access.bell.title')}</strong>
                        <span>{t('access.bell.hint', { n: BELL_MAX })}</span>
                    </div>
                    {list.length === 0 ? (
                        <div className="cp-bell__empty">{t('access.bell.empty')}</div>
                    ) : (
                        <ul className="cp-bell__list">
                            {list.map(e => (
                                <li key={e.id} className={`cp-bell__item cp-bell__item--${e.kind}`}>
                                    <Icon name={KIND_ICON[e.kind] ?? 'info'} size={15} className="cp-bell__icon" />
                                    <div className="cp-bell__text">
                                        {e.title ? <strong>{e.title}</strong> : null}
                                        <span>{e.text}</span>
                                    </div>
                                    <time className="cp-bell__time">{timeOf(e.at)}</time>
                                </li>
                            ))}
                        </ul>
                    )}
                </div>
            ) : null}
        </div>
    );
}

export default NotificationBell;
