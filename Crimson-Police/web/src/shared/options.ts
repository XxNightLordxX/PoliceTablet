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

export function OptionsProvider({ session, children }: { session: Session | null; children?: ReactNode }) {
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
            server: pushed ?? asValues(session?.options),
            defaults: asValues(session?.config?.officerOptions?.defaults),
            setLocal,
        }),
        [local, pushed, session, setLocal],
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
