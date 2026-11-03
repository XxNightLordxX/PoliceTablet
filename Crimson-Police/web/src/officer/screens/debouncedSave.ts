// My options: one save per key after the officer stops changing it (delay ms). cancel(keys) drops the pending saves
// of those keys (a group's Reset, so a change made a moment before it cannot undo the reset); flush() runs every
// pending save at once (the screen closes).

export type Debouncer<V> = {
    later: (key: string, value: V) => void;
    cancel: (keys: string[]) => void;
    flush: () => void;
};

export function makeDebouncer<V>(save: (key: string, value: V) => void, delay: number): Debouncer<V> {
    const timers: Record<string, { id: ReturnType<typeof setTimeout>; value: V }> = {};
    return {
        later(key, value) {
            const old = timers[key];
            if (old) clearTimeout(old.id);
            const id = setTimeout(() => {
                delete timers[key];
                save(key, value);
            }, delay);
            timers[key] = { id, value };
        },
        cancel(keys) {
            for (const key of keys) {
                const p = timers[key];
                if (p) clearTimeout(p.id);
                delete timers[key];
            }
        },
        flush() {
            for (const [key, p] of Object.entries(timers)) {
                clearTimeout(p.id);
                delete timers[key];
                save(key, p.value);
            }
        },
    };
}
