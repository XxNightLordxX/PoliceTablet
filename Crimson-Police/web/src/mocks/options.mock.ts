// Browser mocks of My options: getOptions, server:options:set, the options of this PC (getLocalOptions,
// setLocalOption, the localOptions message) and My keys (getKeyLabels). The sample options stand in for the ones
// later features register. ?options=locked shows the screen with officer options turned off by an admin.

import { emitDebug, registerMock } from '../shared/nui';
import type { OfficerOptionValue } from '../shared/types';
import type { KeyLabel, OptionDef, OptionsView } from '../types/options';
import { buildSession } from './samples';

const MODE = typeof window !== 'undefined' ? new URLSearchParams(window.location.search).get('options') : null;
const LOCKED = MODE === 'locked';

const SCHEMA: OptionDef[] = [
    {
        key: 'board_view',
        kind: 'enum',
        values: ['list', 'cards'],
        default: 'list',
        store: 'server',
        group: 'mission_board',
        order: 10,
    },
    {
        key: 'board_types',
        kind: 'list',
        values: ['traffic', 'pursuit', 'rescue'],
        default: [],
        store: 'server',
        group: 'mission_board',
        order: 20,
    },
    { key: 'hud_sounds', kind: 'bool', default: true, store: 'local', group: 'hud', order: 10 },
    {
        key: 'hud_volume',
        kind: 'number',
        default: 60,
        bounds: { min: 0, max: 100 },
        store: 'local',
        group: 'hud',
        order: 20,
    },
];

const defaults = Object.fromEntries(SCHEMA.map(d => [d.key, d.default])) as Record<string, OfficerOptionValue>;
const server: Record<string, OfficerOptionValue> = { board_view: 'cards' };
const local: Record<string, OfficerOptionValue> = {};

// The mock session's config carries Config.OfficerOptions resolved, as the real getSession sends it.
{
    const cfg = buildSession('officer').config;
    cfg.officerOptions = {
        enabled: true,
        allow: Object.fromEntries(SCHEMA.map(d => [d.key, true])),
        defaults,
        bounds: { hud_volume: { min: 0, max: 100 } },
    };
}

registerMock('request', 'getOptions', (): OptionsView => {
    if (LOCKED) return { enabled: false, schema: [], values: [] };
    const values: Record<string, OfficerOptionValue> = {};
    for (const d of SCHEMA) if (d.store === 'server') values[d.key] = server[d.key] ?? d.default;
    return { enabled: true, schema: SCHEMA, values };
});

registerMock('action', 'server:options:set', (patch: Record<string, OfficerOptionValue> | null) => {
    if (LOCKED) throw new Error('err.option_locked');
    for (const [key, value] of Object.entries(patch ?? {})) {
        const d = SCHEMA.find(x => x.key === key);
        if (!d || d.store !== 'server') throw new Error('err.invalid_payload');
        server[key] = value;
    }
    const values = { ...defaults, ...server };
    emitDebug('push', { topic: 'options', data: { values } });
    return { values };
});

registerMock('client', 'getLocalOptions', () => ({ options: { ...local } }));

registerMock('client', 'setLocalOption', (p: { key?: string; value?: OfficerOptionValue } | null) => {
    const d = SCHEMA.find(x => x.key === p?.key);
    if (!d || d.store !== 'local' || p?.value === undefined) throw new Error('err.invalid_payload');
    let value = p.value;
    if (d.kind === 'number' && typeof value === 'number') {
        value = Math.min(d.bounds?.max ?? value, Math.max(d.bounds?.min ?? value, value));
    }
    local[d.key] = value;
    emitDebug('localOptions', { options: { ...local } });
    return { key: d.key, value, options: { ...local } };
});

registerMock('client', 'getKeyLabels', (): { keys: KeyLabel[] } => {
    if (LOCKED) throw new Error('err.option_locked');
    return {
        keys: [
            { command: 'crimsonpolice_tablet', state: 'set', label: 'F5' },
            { command: 'crimsonpolice_dispatch', state: 'unset' },
            { command: 'crimsonpolice_ready', state: 'unset' },
            { command: 'crimsonpolice_contact', state: 'other' },
        ],
    };
});
