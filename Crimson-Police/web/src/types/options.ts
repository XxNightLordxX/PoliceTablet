// Shapes of My options: the officer options (callback getOptions, action server:options:set) and My keys (client
// action getKeyLabels).

import type { OfficerOptionValue } from '../shared/types';

// One allowed option (CP.Options.view schema row).
export interface OptionDef {
    key: string;
    kind: 'bool' | 'enum' | 'list' | 'number';
    // enum and list: the values offered now
    values?: (string | number)[];
    default: OfficerOptionValue;
    // number: the bounds the officer may pick in
    bounds?: { min?: number; max?: number };
    // 'server' = saved with this character; 'local' = kept on this PC
    store: 'server' | 'local';
    group: string;
    order: number;
}

// getOptions (Lua sends an empty schema or values as [])
export interface OptionsView {
    enabled: boolean;
    schema: OptionDef[] | Record<string, never>;
    values: Record<string, OfficerOptionValue> | never[];
}

// getKeyLabels: one Crimson-Police key mapping and the key bound to it
export interface KeyLabel {
    command: string;
    // set = bound to a key with a name; other = a mouse or pad button; unset = not bound
    state: 'set' | 'other' | 'unset';
    label?: string;
}
