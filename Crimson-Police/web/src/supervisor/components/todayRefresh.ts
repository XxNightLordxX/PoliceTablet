// Supervisor UI · Department: today at a glance asks again the moment a side panel action is taken (points given, a
// ban set or lifted, a cooldown cleared, a commendation, a training pairing), not only on its 30 s poll.
// todayChanged() tells it; useTodayChanged(fn) runs fn on each tell while the component is shown.

import { useEffect, useRef } from 'react';

const listeners = new Set<() => void>();

export function todayChanged(): void {
    for (const fn of [...listeners]) fn();
}

export function useTodayChanged(fn: () => void): void {
    const ref = useRef(fn);
    ref.current = fn;
    useEffect(() => {
        const call = () => ref.current();
        listeners.add(call);
        return () => {
            listeners.delete(call);
        };
    }, []);
}
