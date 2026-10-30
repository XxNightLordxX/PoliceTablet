// The officer options (CP.OptionDefs) as the open UI and the HUD see them. A 'local' option (a look or a sound) comes

import {
    createContext,
    createElement,
    useCallback,
    useContext,
    useEffect,
    useMemo,
    useState,
    type ReactNode,
} from 'react';
import { formatDistance, type DistanceUnits } from './format';
import { usePush } from './hooks';
import { clientAction, useNuiEvent } from './nui';
import type { ApiResult, OfficerOptionValue, Session } from './types';

type OptionValues = Record<string, OfficerOptionValue>;

export interface OptionsContextValue {
    // this PC's 'local' options (the latest localOptions message)
    local: OptionValues;
    // the officer's 'server' options (the session's, then each push 'options')
    server: OptionValues;
    defaults: OptionValues;
    // Sets a 'local' option on this PC (client action setLocalOption); the reply carries every local value.
    setLocal: (
        key: string,
        value: OfficerOptionValue,
    ) => Promise<ApiResult<{ key: string; value: OfficerOptionValue }>>;
}

const OptionsContext = createContext<OptionsContextValue>({
    local: {},
    server: {},
    defaults: {},
    setLocal: async () => ({ ok: false, error: 'err.no_response' }),
});

// A JSON object of values: Lua sends an empty table as [] (no options yet).
function asValues(v: unknown): OptionValues {
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as OptionValues) : {};
}

// The text size factor of the officer option textSize (step O5): 'large' = 1.15, anything else 1. It is the CSS
// variable --cp-fs-scale on the tablet and the HUD column (styles/base.css).
export function textScaleOf(v: unknown): number {
    return v === 'large' ? 1.15 : 1;
}

// session: the open UI's (kept after it closes). ambient: the server options the theme message carried (hudLook,
// textSize), used over the session's while that message is newer than the session (App.tsx).
export function OptionsProvider({
    session,
    ambient,
    children,
}: {
    session: Session | null;
    ambient?: OptionValues | null;
    children?: ReactNode;
}) {
    const [local, setLocalValues] = useState<OptionValues>({});
    const [pushed, setPushed] = useState<OptionValues | null>(null);
    useNuiEvent('localOptions', m => setLocalValues(asValues(m.options)));
    usePush<{ values?: unknown }>('options', d => setPushed(asValues(d?.values)));
    // a new session carries the current server values: a pushed copy is older
    useEffect(() => setPushed(null), [session]);

    const setLocal = useCallback(async (key: string, value: OfficerOptionValue) => {
        const res = await clientAction<{ key: string; value: OfficerOptionValue; options?: unknown }>(
            'setLocalOption',
            { key, value },
        );
        if (res.ok && res.data) setLocalValues(asValues(res.data.options));
        return res;
    }, []);

    const value = useMemo<OptionsContextValue>(
        () => ({
            local,
            server: pushed ?? (ambient ? { ...asValues(session?.options), ...ambient } : asValues(session?.options)),
            defaults: asValues(session?.config?.officerOptions?.defaults),
            setLocal,
        }),
        [local, pushed, session, ambient, setLocal],
    );
    return createElement(OptionsContext.Provider, { value }, children);
}

export function useOptions(): OptionsContextValue {
    return useContext(OptionsContext);
}

// One option's value now: this PC's, else the session's, else the department default (undefined: unknown key).
export function useOption<T extends OfficerOptionValue = OfficerOptionValue>(key: string): T | undefined {
    const { local, server, defaults } = useContext(OptionsContext);
    if (key in local) return local[key] as T;
    if (key in server) return server[key] as T;
    return defaults[key] as T | undefined;
}

// The officer's distance format (option distanceUnits, kept on this PC): metres -> "1.2 km" or "0.7 mi".
export function useFormatDistance(): (metres: number | null | undefined) => string {
    const units: DistanceUnits = useOption('distanceUnits') === 'imperial' ? 'imperial' : 'metric';
    return useCallback((metres: number | null | undefined) => formatDistance(metres, units), [units]);
}
