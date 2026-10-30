// The Crimson-Police toast bus. App renders the stack (<Toasts/>, top-right); anything can raise one: toast('error',
// t('err.timeout')). Lua toasts arrive as `notify`.

import type { Notification, NotificationKind } from './types';

type Listener = (n: Notification) => void;
const listeners = new Set<Listener>();
let seq = 0;

export type ToastTime = 'short' | 'normal' | 'long';

// How long a toast stays (ms) for the officer option toastTime (step O6, shared/options_popups.lua); the Lua toasts
// get theirs from the same table in modules/tablet/client.lua.
export const TOAST_MS: Record<ToastTime, Record<NotificationKind, number>> = {
    short: { info: 3000, success: 3000, warning: 5000, error: 5000 },
    normal: { info: 5000, success: 5000, warning: 7000, error: 7000 },
    long: { info: 8000, success: 8000, warning: 12000, error: 12000 },
};

export const TOAST_DEFAULT_MS: Record<NotificationKind, number> = TOAST_MS.normal;

// The officer's toastTime now (App.tsx ToastTimePref sets it from the option).
let toastTime: ToastTime = 'normal';

export function setToastTime(v: unknown): void {
    toastTime = v === 'short' || v === 'long' ? v : 'normal';
}

// The time a toast of this kind stays with the officer's toastTime (or the one given).
export function toastMs(kind: NotificationKind, time: unknown = toastTime): number {
    const table = time === 'short' || time === 'long' ? TOAST_MS[time] : TOAST_MS.normal;
    return table[kind] ?? table.info;
}

// Raise a toast. `text` and `title` are already translated. Returns the toast id.
export function toast(kind: NotificationKind, text: string, opts: { title?: string; duration?: number } = {}): string {
    const id = `ui-${Date.now()}-${++seq}`;
    const n: Notification = { id, kind, text, title: opts.title, duration: opts.duration ?? toastMs(kind) };
    listeners.forEach(fn => fn(n));
    return id;
}

// Deliver an already-built notification (used for Lua `notify` messages).
export function pushNotification(n: Notification): void {
    listeners.forEach(fn => fn(n));
}

export function subscribeToasts(fn: Listener): () => void {
    listeners.add(fn);
    return () => {
        listeners.delete(fn);
    };
}
