// Step WF2 (smoother workflows): an action whose reply carries the screen's fresh view applies it at once, so the
// screen needs no second request after the action. A reply without it (an older server) asks again, as before.

// The view under data[key] when it is an object, else null.
export function replyView<T>(data: unknown, key: string): T | null {
    if (!data || typeof data !== 'object') return null;
    const v = (data as Record<string, unknown>)[key];
    return v && typeof v === 'object' ? (v as T) : null;
}

// Apply the reply's view through set(), or call refetch() when it has none. True when the view was applied.
export function applyReplyView<T>(data: unknown, key: string, set: (v: T) => void, refetch: () => void): boolean {
    const v = replyView<T>(data, key);
    if (v) {
        set(v);
        return true;
    }
    refetch();
    return false;
}
