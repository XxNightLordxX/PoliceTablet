// Core browser mocks: sessions for the three UIs (with the officer's look, level and picture), the pinned run
// (fallback), logo reports, the sidebar badge counts, Config health and the tablet access view.

import { registerMock, request } from '../shared/nui';
import type { ConfigHealthItem, NavCounts, Prefs, Session, UiKind } from '../shared/types';
import type { TabletAccessView } from '../types/access';
import type { ProfileEdit } from '../types/profile';
import { devState } from './devState';
import { buildSession, sampleRun } from './samples';

// ?uiScale=0.85 or ?uiScale=1.25 opens the tablet at that size, ?look=midnight (high_contrast, colourblind) with that
// appearance and ?accent=%234cc9f0 with that accent.
const PARAMS = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : new URLSearchParams();

function numberParam(name: string): number | null {
    const v = PARAMS.get(name);
    const n = v === null ? NaN : Number(v);
    return isFinite(n) ? n : null;
}

// URL overrides win over the profile mock's saved look.
function withUrlLook(prefs: Prefs): Prefs {
    const scale = numberParam('uiScale');
    return {
        ...prefs,
        uiScale: scale ?? prefs.uiScale,
        appearance: PARAMS.get('look') ?? prefs.appearance,
        accent: PARAMS.get('accent') ?? prefs.accent,
    };
}

const DEFAULT_PREFS: Prefs = { appearance: 'department', accent: null, uiScale: 1, callsMuted: false };

async function sessionFor(ui: UiKind): Promise<Session> {
    const s = buildSession(ui);
    if (ui === 'admin' || !s.officer) return s;
    // the profile mock keeps the look an officer saves: the session follows it
    const edit = await request<ProfileEdit>('getProfileEdit', {});
    const saved = edit.ok && edit.data ? edit.data : null;
    const level = saved?.level ?? {
        n: 12,
        label: 'Patrol Officer',
        badge: 'bronze',
        xp: 1780,
        levelXp: 1650,
        nextLevelXp: 1900,
        prestige: 0,
    };
    return {
        ...s,
        officer: {
            ...s.officer,
            avatar: saved?.avatar ?? { kind: 'initials', value: null, initials: 'JD', frame: level.badge },
            level,
        },
        prefs: withUrlLook(saved?.prefs ?? DEFAULT_PREFS),
        access: { via: 'command', desk: null },
        config: { ...s.config, format: s.config.format ?? { currency: '$', currencyAfter: false } },
    };
}

registerMock('request', 'getSession', (args: { ui?: UiKind } | null) => sessionFor(args?.ui ?? 'officer'));

// Fallback: the Active Mission feature may register a richer 'getRun' in its own mock file.
registerMock('request', 'getRun', () => (devState.runActive ? sampleRun() : null), { fallback: true });

registerMock('client', 'logoFailed', (payload: unknown) => {
    console.info('[crimson-police:mock] logoFailed', payload);
    return true;
});

// ============================================================================
//                                SIDEBAR BADGES
// ============================================================================

registerMock('request', 'getNavCounts', (): NavCounts => ({
    invites: 1,
    calls: 2,
    review: 3,
    commendations: 1,
    rewards: 0,
    onRun: devState.runActive,
}));

// ============================================================================
//                           CONFIG HEALTH AND DESKS
// ============================================================================

registerMock('request', 'admin:getConfigHealth', (): ConfigHealthItem[] => [
    { check: 'desks', level: 'warn', text: 'Desk 2 (Sandy Shores office): unknown department "bcso"' },
    { check: 'items', level: 'ok', text: 'The tablet item is off (every way opens the tablet without it)' },
    { check: 'desks', level: 'ok', text: '1 of 2 mission desks ready' },
    { check: 'colours', level: 'ok', text: 'Department colours and personal accents are valid' },
    { check: 'tweaks', level: 'ok', text: 'No built-in mission tweaks' },
    { check: 'locale', level: 'ok', text: 'locales/en.json loaded (4210 texts)' },
    { check: 'avatars', level: 'ok', text: 'Profile picture links are off' },
    { check: 'rewards', level: 'ok', text: 'Item rewards: off (example pool available)' },
]);

registerMock('request', 'admin:getTabletAccess', (): TabletAccessView => ({
    ways: { command: true, keybind: true, item: true, desk: true, requireItem: false },
    item: null,
    deskDistance: 3,
    desks: [
        {
            index: 1,
            label: 'Mission Row PD front desk',
            coords: { x: 441.2, y: -978.9, z: 30.69 },
            size: { x: 1.2, y: 0.8, z: 1 },
            rotation: 0,
            departments: null,
            prop: null,
        },
        {
            index: 2,
            label: 'Sandy Shores office',
            coords: { x: 1853.2, y: 3689.6, z: 34.27 },
            size: { x: 1.2, y: 0.8, z: 1 },
            rotation: 30,
            departments: ['sast'],
            prop: 'prop_laptop_01a',
        },
    ],
    accents: {
        sast: [
            { colour: '#f2c230', level: null },
            { colour: '#4cc9f0', level: null },
            { colour: '#80ed99', level: 10 },
            { colour: '#ff8fab', level: 25 },
            { colour: '#c77dff', level: 40 },
        ],
        fib: [
            { colour: '#c9a227', level: null },
            { colour: '#e9ecef', level: null },
        ],
    },
    appearances: ['department', 'midnight', 'high_contrast', 'colourblind'],
}));
