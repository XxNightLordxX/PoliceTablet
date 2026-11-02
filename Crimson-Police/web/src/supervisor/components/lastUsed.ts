// Supervisor dialogs open with the values last used (step WF2, Config.Tablet.supervisorRemember): Give points (the

import type { Session } from '../../shared/types';

export type LastUsedForm = 'award' | 'ban' | 'cooldown';
export interface LastUsedValues {
    number?: number;
    reason?: string;
}

const store = new Map<LastUsedForm, LastUsedValues>();

// The session's supervisorNav.remember (an older session = off).
export function rememberOn(session: Session | null | undefined): boolean {
    return session?.config?.supervisorNav?.remember === true;
}

// The values a dialog opens with: the last ones while on, else none.
export function lastUsed(form: LastUsedForm, on: boolean): LastUsedValues {
    if (!on) return {};
    return { ...(store.get(form) ?? {}) };
}

// Keep the values of a successful submit (only while on).
export function keepLastUsed(form: LastUsedForm, on: boolean, values: LastUsedValues): void {
    if (!on) return;
    const reason = typeof values.reason === 'string' ? values.reason.trim().slice(0, 200) : undefined;
    const number = typeof values.number === 'number' && Number.isFinite(values.number) ? values.number : undefined;
    store.set(form, { number, reason });
}

// The number a dialog opens with: the last one inside min..max, else the fallback (the admin's minimum).
export function startNumber(last: number | undefined, min: number, max: number | undefined, fallback: number): number {
    if (typeof last !== 'number' || !Number.isFinite(last)) return fallback;
    if (last < min) return fallback;
    if (max !== undefined && last > max) return fallback;
    return Math.floor(last);
}

// Walks only: forget every kept value.
export function resetLastUsed(): void {
    store.clear();
}
