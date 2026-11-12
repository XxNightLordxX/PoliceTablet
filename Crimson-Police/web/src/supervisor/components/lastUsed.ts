// Supervisor action forms open with the values last used: the values of the last successful Give points (points,
// reason), Mission ban (hours, reason; never a lift) and Clear cooldown (reason), kept in the page's memory only
// (until Crimson-Police restarts or the player reconnects), so a second award or ban in a row needs no typing.

// Supervisor action forms open with the values last used: the values of the last successful Give points (points,
// reason), Mission ban (hours, reason; never a lift) and Clear cooldown (reason), kept in the page's memory only
// (until Crimson-Police restarts or the player reconnects), so a second award or ban in a row needs no typing.
// startNumber() keeps a number inside the control's current min..max, else the minimum. The server checks every value
// again.

export type LastUsedForm = 'award' | 'ban' | 'cooldown';
export interface LastUsedValues {
    number?: number;
    reason?: string;
}

const store = new Map<LastUsedForm, LastUsedValues>();

// The values a dialog opens with: the last ones (none yet = {}).
export function lastUsed(form: LastUsedForm): LastUsedValues {
    return { ...(store.get(form) ?? {}) };
}

// Keep the values of a successful submit.
export function keepLastUsed(form: LastUsedForm, values: LastUsedValues): void {
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
