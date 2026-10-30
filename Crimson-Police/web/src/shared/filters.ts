// Remember my filters (step O9): with the officer option rememberFilters on (this PC), a screen's filter starts from
// the 'local' option filters (entries 'screen.part:value', e.g. 'dispatch.filter:near'; not a row of My options) and
// each change is saved there. Off (as before): every screen starts from its own default.

import { useCallback, useRef, useState } from 'react';
import { useOption, useOptions } from './options';

// The value saved for a part ('dispatch.filter'), or null.
export function filterOf(list: unknown, part: string): string | null {
    if (!Array.isArray(list)) return null;
    const prefix = `${part}:`;
    for (const x of list) {
        if (typeof x === 'string' && x.startsWith(prefix)) return x.slice(prefix.length);
    }
    return null;
}

// The list with the part set to value (one entry per part).
export function withFilter(list: unknown, part: string, value: string): string[] {
    const prefix = `${part}:`;
    const kept = Array.isArray(list)
        ? list.filter((x): x is string => typeof x === 'string' && !x.startsWith(prefix))
        : [];
    return [...kept, prefix + value];
}

// [value, set] for one filter of a screen. valid: a saved value that no longer fits is ignored.
export function useRememberedFilter<T extends string>(
    part: string,
    fallback: T,
    valid?: (v: string) => boolean,
): [T, (v: T) => void] {
    const remember = useOption('rememberFilters') === true;
    const saved = useOption('filters');
    const { setLocal } = useOptions();
    const [value, setValue] = useState<T>(() => {
        const v = remember ? filterOf(saved, part) : null;
        return v !== null && (!valid || valid(v)) ? (v as T) : fallback;
    });
    // the latest saved list: two filters changed one after the other both stay
    const latest = useRef(saved);
    latest.current = saved;
    const set = useCallback(
        (v: T) => {
            setValue(v);
            if (!remember) return;
            const next = withFilter(latest.current, part, v);
            latest.current = next;
            void setLocal('filters', next);
        },
        [remember, part, setLocal],
    );
    return [value, set];
}
