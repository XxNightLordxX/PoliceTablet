// Browser mocks of My options: getOptions, server:options:set, the options of this PC (getLocalOptions,
// setLocalOption, the localOptions message) and My keys (getKeyLabels). ?options=locked: officer options off.

import { emitDebug, registerMock } from '../shared/nui';
import type { OfficerOptionValue } from '../shared/types';
import type { KeyLabel, OptionDef, OptionsView } from '../types/options';
import { buildSession, MOCK_DEPARTMENTS } from './samples';

const PARAMS = new URLSearchParams(typeof window !== 'undefined' ? window.location.search : '');
const MODE = PARAMS.get('options');
const LOCKED = MODE === 'locked';

const SCHEMA: OptionDef[] = [
    {
        key: 'favouriteTypes',
        kind: 'list',
        values: ['patrol', 'training', 'investigation', 'tactical'],
        default: [],
        store: 'server',
        group: 'board',
        order: 10,
    },
    {
        key: 'hiddenTypes',
        kind: 'list',
        values: ['patrol', 'training', 'investigation', 'tactical'],
        default: [],
        store: 'server',
        group: 'board',
        order: 20,
    },
    { key: 'skipAcceptConfirm', kind: 'bool', default: false, store: 'server', group: 'board', order: 30 },
    {
        key: 'usualTwists',
        kind: 'list',
        values: ['armored_hostiles', 'time_crunch', 'radio_silence'],
        default: [],
        store: 'server',
        group: 'board',
        order: 40,
    },
    { key: 'skipClaimConfirm', kind: 'bool', default: false, store: 'server', group: 'dispatch', order: 10 },
    {
        key: 'callAlerts',
        kind: 'enum',
        values: ['all', 'favourites'],
        default: 'all',
        store: 'server',
        group: 'dispatch',
        order: 20,
    },
    { key: 'dispatchKeyAfterCall', kind: 'bool', default: false, store: 'server', group: 'dispatch', order: 30 },
    {
        key: 'hudSide',
        kind: 'enum',
        values: ['right', 'left'],
        default: 'right',
        store: 'local',
        group: 'hud',
        order: 10,
    },
    {
        key: 'hudScale',
        kind: 'number',
        default: 1,
        bounds: { min: 0.8, max: 1.3 },
        store: 'local',
        group: 'hud',
        order: 20,
    },
    { key: 'hudCompact', kind: 'bool', default: false, store: 'local', group: 'hud', order: 30 },
    { key: 'reduceMotion', kind: 'bool', default: false, store: 'local', group: 'hud', order: 40 },
    { key: 'hudLook', kind: 'bool', default: false, store: 'server', group: 'look', order: 10 },
    {
        key: 'openOn',
        kind: 'enum',
        values: ['last', 'home', 'active_on_run'],
        default: 'last',
        store: 'server',
        group: 'opening',
        order: 10,
    },
    { key: 'rememberFilters', kind: 'bool', default: false, store: 'local', group: 'opening', order: 20 },
    {
        key: 'textSize',
        kind: 'enum',
        values: ['normal', 'large'],
        default: 'normal',
        store: 'server',
        group: 'look',
        order: 20,
    },
    {
        key: 'toastTime',
        kind: 'enum',
        values: ['short', 'normal', 'long'],
        default: 'normal',
        store: 'local',
        group: 'popups',
        order: 10,
    },
    {
        key: 'resultTime',
        kind: 'number',
        default: 25,
        bounds: { min: 8, max: 60 },
        store: 'local',
        group: 'popups',
        order: 20,
    },
    { key: 'quietRun', kind: 'bool', default: false, store: 'local', group: 'popups', order: 30 },
    { key: 'keyHints', kind: 'bool', default: true, store: 'local', group: 'popups', order: 40 },
    { key: 'soundCalls', kind: 'bool', default: true, store: 'local', group: 'sounds', order: 10 },
    { key: 'soundUnit', kind: 'bool', default: true, store: 'local', group: 'sounds', order: 20 },
    { key: 'soundCues', kind: 'bool', default: true, store: 'local', group: 'sounds', order: 30 },
    { key: 'abandonConfirm', kind: 'bool', default: true, store: 'server', group: 'run', order: 10 },
    { key: 'skipRecalcConfirm', kind: 'bool', default: false, store: 'server', group: 'run', order: 20 },
    {
        key: 'distanceUnits',
        kind: 'enum',
        values: ['metric', 'imperial'],
        default: 'metric',
        store: 'local',
        group: 'run',
        order: 30,
    },
];

const defaults = Object.fromEntries(SCHEMA.map(d => [d.key, d.default])) as Record<string, OfficerOptionValue>;
const server: Record<string, OfficerOptionValue> = {};
// Mission Board (step O8): ?fav=tactical,patrol ?hide=training ?oneClick=1
const listParam = (name: string) => (PARAMS.get(name) ?? '').split(',').filter(Boolean);
if (listParam('fav').length) server.favouriteTypes = listParam('fav');
if (listParam('hide').length) server.hiddenTypes = listParam('hide');
if (PARAMS.get('oneClick') === '1') server.skipAcceptConfirm = true;
// My usual twists (step O15): ?usual=time_crunch,armored_hostiles
if (listParam('usual').length) server.usualTwists = listParam('usual');
if (PARAMS.get('oneClickClaim') === '1') server.skipClaimConfirm = true;
// During a mission (step O10): ?abandonConfirm=0 (Abandon pressed twice) ?oneClickRecalc=1 ?units=imperial (with
// ?hud=progress: miles on the HUD)
if (PARAMS.get('abandonConfirm') === '0') server.abandonConfirm = false;
if (PARAMS.get('oneClickRecalc') === '1') server.skipRecalcConfirm = true;
const local: Record<string, OfficerOptionValue> = {};
if (PARAMS.get('hudSide') === 'left') local.hudSide = 'left';
if (PARAMS.get('rememberFilters') === '1') local.rememberFilters = true;
if (PARAMS.get('units') === 'imperial') local.distanceUnits = 'imperial';
if (PARAMS.get('hudCompact') === '1') local.hudCompact = true;
if (PARAMS.get('reduceMotion') === '1') local.reduceMotion = true;
if (Number(PARAMS.get('hudScale')) > 0) local.hudScale = Math.min(1.3, Math.max(0.8, Number(PARAMS.get('hudScale'))));
const toastTime = PARAMS.get('toastTime');
if (toastTime === 'short' || toastTime === 'long') local.toastTime = toastTime;
if (Number(PARAMS.get('resultTime')) > 0) {
    local.resultTime = Math.round(Math.min(60, Math.max(8, Number(PARAMS.get('resultTime')))));
}
// the mock session carries no options: the board's come as the push 'options' once the tablet is open
if (Object.keys(server).length) emitDebug('push', { topic: 'options', data: { values: { ...server } } }, 1500);
// the client sends the options of this PC on the NUI ready
if (Object.keys(local).length) emitDebug('localOptions', { options: { ...local } }, 300);
if (PARAMS.get('hudLook') === '1') server.hudLook = true;
if (PARAMS.get('textSize') === 'large') server.textSize = 'large';
// like the client's login theme: the officer's look and his hudLook / textSize, before the tablet opens
if (server.hudLook !== undefined || server.textSize !== undefined) {
    emitDebug(
        'theme',
        {
            theme: MOCK_DEPARTMENTS.sast.theme,
            prefs: { appearance: PARAMS.get('look') ?? 'department', accent: PARAMS.get('accent') },
            options: { hudLook: server.hudLook ?? false, textSize: server.textSize ?? 'normal' },
        },
        700,
    );
}

// The mock session's config carries Config.OfficerOptions resolved, as the real getSession sends it.
{
    const cfg = buildSession('officer').config;
    cfg.officerOptions = {
        enabled: true,
        allow: Object.fromEntries(SCHEMA.map(d => [d.key, true])),
        defaults,
        bounds: { hudScale: { min: 0.8, max: 1.3 }, resultTime: { min: 8, max: 60 } },
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
        // like shared/options_board.lua: the board keeps at least one type
        if (key === 'hiddenTypes' && Array.isArray(value) && (d.values ?? []).every(v => value.includes(v)))
            throw new Error('err.option_hide_all');
        server[key] = value;
    }
    const values = { ...defaults, ...server };
    emitDebug('push', { topic: 'options', data: { values } });
    return { values };
});

registerMock('client', 'getLocalOptions', () => ({ options: { ...local } }));

registerMock('client', 'setLocalOption', (p: { key?: string; value?: OfficerOptionValue } | null) => {
    // the remembered filters (step O9): a 'local' list that is not a row of My options
    if (p?.key === 'filters' && Array.isArray(p.value)) {
        local.filters = p.value;
        emitDebug('localOptions', { options: { ...local } });
        return { key: 'filters', value: p.value, options: { ...local } };
    }
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

// step O11: the keys the hints name (the ready key K, the Dispatch key F6; the contact key is not bound here).
registerMock('client', 'getKeyHints', (): { keys: Record<string, string> } => {
    if (local.keyHints === false) return { keys: {} };
    return { keys: { tablet: 'F5', dispatch: 'F6', ready: 'K' } };
});
