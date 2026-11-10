// Browser mocks for Admin UI → Settings and the mission switches (a small sample of the real list).

import { registerMock } from '../shared/nui';
import type {
    MissionSwitchView,
    PresetPreview,
    SettingsData,
    SettingsHistory,
    SettingsHistoryRow,
    SettingsReply,
    SettingView,
} from '../types/settings';

const now = () => Math.floor(Date.now() / 1000);

function s(path: string, kind: SettingView['kind'], value: unknown, desc: string, extra: Partial<SettingView> = {}) {
    const key = path.split('.').pop() ?? path;
    return {
        path,
        key,
        label: key.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, c => c.toUpperCase()),
        desc,
        kind,
        value,
        isSet: value !== undefined,
        default: value,
        defaultSet: value !== undefined,
        changed: false,
        ...extra,
    } as SettingView;
}

const MONEY = { min: 0, max: 1000000, integer: true };
// Config.FeatureRewards: each feature and its shipped money
const FEATURES: [string, number][] = [
    ['suspect', 0],
    ['surrender', 300],
    ['ftoSignOff', 250],
    ['ftoComplete', 1000],
    ['supAward', 5],
];

// Config.Markers.parts: the prisoner van (its own switch, shipped on) and a few extra parts, shipped look
const BLIP_PARTS: [string, number, number, boolean][] = [
    ['prisonerVan', 285, 3, true],
    ['coronerVan', 67, 40, false],
    ['evidence', 1, 0, false],
    ['hidingSpot', 1, 17, false],
    ['partner', 1, 3, false],
];
// Config.Markers.kinds: two kinds of objective blip
const BLIP_KINDS: [string, number, number][] = [
    ['start', 162, 5],
    ['hostile', 1, 1],
];

const data: SettingsData = {
    sections: [
        {
            key: 'general',
            title: 'General',
            file: 'config',
            group: 'server',
            changed: 0,
            count: 2,
            groups: [
                {
                    path: '',
                    label: '',
                    desc: '',
                    settings: [
                        s('Debug', 'boolean', false, 'true = each module prints tagged debug lines', {
                            common: true,
                            label: 'Debug lines in the server console',
                            help: 'Prints what each part of Crimson-Police does, for finding a problem.',
                        }),
                        s('Locale', 'enum', 'en', '', { options: ['en'], restart: true, common: true }),
                        // the Simple view sends this one to Missions (it is kept per mission there)
                        s('DisabledLocations', 'json', {}, 'locations switched off, per mission id'),
                    ],
                },
            ],
        },
        {
            key: 'tablet_and_commands',
            title: 'Tablet and commands',
            file: 'config',
            group: 'tablet',
            changed: 1,
            count: 6,
            groups: [
                {
                    path: 'Tablet',
                    label: 'Tablet',
                    desc: '',
                    settings: [
                        s('Tablet.title', 'text', 'Crimson-Police', 'app title on every screen'),
                        s('Tablet.command', 'text', 'CrimsonPolice', 'opens the Officer UI', { restart: true }),
                        s(
                            'Tablet.item',
                            'optionalText',
                            false,
                            'ox_inventory item name that also opens the tablet, or false',
                        ),
                        s(
                            'Tablet.deskDistance',
                            'number',
                            4.5,
                            'metres: walking further than this from the desk closes the tablet',
                            {
                                changed: true,
                                common: true,
                                label: 'Distance from the desk before the tablet closes',
                                help: 'Metres an officer may walk from a police desk before the tablet closes.',
                                default: 3.0,
                                integer: false,
                                min: 0,
                                by: 'ABC12345',
                                at: now() - 600,
                            },
                        ),
                    ],
                },
                {
                    path: 'Tablet.access',
                    label: 'Tablet › Access',
                    desc: 'which ways open the Officer UI; the server refuses a way that is off',
                    settings: [
                        s(
                            'Tablet.access.requireItem',
                            'boolean',
                            false,
                            'true = every way except a desk needs the item in the inventory',
                        ),
                    ],
                },
                {
                    path: 'AdminTheme',
                    label: 'Admin theme',
                    desc: '',
                    settings: [s('AdminTheme.primary', 'colour', '#a4161a', '')],
                },
            ],
        },
        {
            key: 'limits_and_cash',
            title: 'Limits and cash',
            file: 'config',
            group: 'pay',
            changed: 0,
            count: 2,
            groups: [
                {
                    path: 'Limits',
                    label: 'Limits',
                    desc: '',
                    settings: [
                        // below 4 the trial mock answers with missions it breaks (the 'breaks missions' dialog)
                        s('Limits.maxUnitSize', 'number', 6, 'officers in one unit at most', {
                            integer: true,
                            min: 1,
                            max: 12,
                            reload: true,
                        }),
                    ],
                },
                {
                    path: 'Cash',
                    label: 'Cash',
                    desc: '',
                    settings: [
                        // society opens the department balances dialog (admin:previewCashSource)
                        s(
                            'Cash.source',
                            'enum',
                            'server',
                            "who pays: 'server' (money is created) or 'society' (the department's account)",
                            { options: ['server', 'society'] },
                        ),
                    ],
                },
            ],
        },
        {
            key: 'blocks',
            title: 'Mission Builder ranges (blocks.lua)',
            file: 'blocks',
            group: 'missions',
            changed: 0,
            count: 2,
            groups: [
                {
                    path: 'Blocks.escort',
                    label: 'Blocks › Escort',
                    desc: '',
                    settings: [
                        s('Blocks.escort.speed', 'range', [20, 120, 60], '', { size: 3, integer: true, reload: true }),
                        s(
                            'Blocks.escort.style.options',
                            'list',
                            ['careful', 'normal', 'fast'],
                            'always lane-following',
                            {
                                item: 'string',
                                reload: true,
                            },
                        ),
                    ],
                },
            ],
        },
        {
            key: 'real_players',
            title: 'Real players',
            file: 'config',
            group: 'police',
            changed: 0,
            count: 2,
            groups: [
                {
                    path: 'RealPlayers.liveCrime',
                    label: 'Live crimes',
                    desc: '',
                    settings: [
                        s(
                            'RealPlayers.liveCrime.enabled',
                            'boolean',
                            false,
                            'true = real players doing crimes become suspects',
                        ),
                        s('RealPlayers.liveCrime.cash', 'boolean', false, 'true = a live case pays cash', {
                            money: true,
                        }),
                    ],
                },
            ],
        },
        // Admin UI -> Map markers: the objective's settings, two kinds, the extra
        // parts' switch, a few parts, the rules
        {
            key: 'map_markers',
            title: 'Map markers',
            file: 'config',
            group: 'missions',
            changed: 0,
            count: 0,
            groups: [
                {
                    path: 'Markers',
                    label: 'Map markers',
                    desc: '',
                    settings: [
                        s('Markers.enabled', 'boolean', true, 'false = no objective blip or line'),
                        s('Markers.route', 'boolean', true, 'false = no GPS line to the objective'),
                        ...BLIP_KINDS.flatMap(([id, sprite, colour]) => [
                            s(`Markers.kinds.${id}.sprite`, 'number', sprite, 'blip id', { min: 0, max: 965 }),
                            s(`Markers.kinds.${id}.colour`, 'number', colour, 'colour id', { min: 0, max: 85 }),
                            s(`Markers.kinds.${id}.scale`, 'number', 0.9, 'size', { min: 0.3, max: 2, integer: false }),
                        ]),
                        s('Markers.extraParts', 'boolean', false, 'true = the other parts of a mission show too'),
                        s('Markers.refreshEvery', 'number', 3, 'seconds between checks', { min: 1, max: 30 }),
                        ...BLIP_PARTS.flatMap(([id, sprite, colour, on]) => [
                            s(`Markers.parts.${id}.on`, 'boolean', on, 'true = this part shows'),
                            s(`Markers.parts.${id}.sprite`, 'number', sprite, 'blip id', { min: 0, max: 965 }),
                            s(`Markers.parts.${id}.colour`, 'number', colour, 'colour id', { min: 0, max: 85 }),
                            s(`Markers.parts.${id}.scale`, 'number', 0.7, 'size', {
                                min: 0.3,
                                max: 2,
                                integer: false,
                            }),
                            s(`Markers.parts.${id}.label`, 'text', '', "its name ('' = built-in)"),
                            s(`Markers.parts.${id}.shortRange`, 'boolean', false, 'true = near only'),
                        ]),
                        s('Markers.rules', 'json', {}, 'who sees a part, by part name'),
                    ],
                },
            ],
        },
        // the departments (Map markers rules pick from their keys and jobs)
        {
            key: 'departments',
            title: 'Departments',
            file: 'config',
            group: 'police',
            changed: 0,
            count: 0,
            groups: [
                {
                    path: 'Departments',
                    label: 'Departments',
                    desc: '',
                    settings: [
                        s('Departments.sast.label', 'text', 'San Andreas State Troopers', 'shown name'),
                        s('Departments.sast.jobs', 'list', ['sast'], 'its jobs', { item: 'string' }),
                        s('Departments.fib.label', 'text', 'Federal Investigation Bureau', 'shown name'),
                        s('Departments.fib.jobs', 'list', ['fib'], 'its jobs', { item: 'string' }),
                    ],
                },
            ],
        },
        // Admin UI -> Money -> Rewards: what each feature pays, its account and items
        {
            key: 'feature_rewards',
            title: 'Feature rewards',
            file: 'config',
            group: 'pay',
            changed: 0,
            count: 0,
            groups: [
                {
                    path: 'FeatureRewards',
                    label: 'Feature rewards',
                    desc: '',
                    settings: [
                        ...['patrol', 'tactical'].flatMap(k => [
                            s(`MissionTypes.${k}.label`, 'text', k === 'patrol' ? 'Patrol' : 'Tactical', 'shown name'),
                            s(`MissionTypes.${k}.payout`, 'number', k === 'patrol' ? 250 : 800, 'dollars', MONEY),
                        ]),
                        s('Cash.account', 'enum', 'bank', "'bank' or 'cash'", { options: ['bank', 'cash'] }),
                        s('Rewards.enabled', 'boolean', false, 'true = officers can earn items'),
                        s('Rewards.byType', 'json', {}, 'chance per roll, rolls per run, and a weighted pool'),
                        s(
                            'RealPlayers.liveCrime.items',
                            'boolean',
                            false,
                            'true = a live case rolls the item rewards of its type',
                        ),
                        s('RealPlayers.volunteer.cash', 'boolean', false, 'true = it pays the officers cash'),
                        s(
                            'RealPlayers.volunteer.items',
                            'boolean',
                            false,
                            'true = it rolls the item rewards of its type',
                        ),
                        ...FEATURES.flatMap(([k, money]) => [
                            s(`FeatureRewards.${k}.enabled`, 'boolean', false, 'true = this feature pays'),
                            ...(k === 'suspect'
                                ? [
                                      s('FeatureRewards.suspect.money.got_away', 'number', 1500, 'dollars', MONEY),
                                      s('FeatureRewards.suspect.money.caught', 'number', 500, 'dollars', MONEY),
                                      s('FeatureRewards.suspect.byType', 'json', {}, 'dollars by mission type'),
                                  ]
                                : [s(`FeatureRewards.${k}.money`, 'number', money, 'dollars', MONEY)]),
                            ...(k === 'supAward'
                                ? [s('FeatureRewards.supAward.maxMoney', 'number', 2500, 'dollars', MONEY)]
                                : []),
                            s(`FeatureRewards.${k}.account`, 'enum', k === 'suspect' ? 'cash' : 'bank', 'paid as', {
                                options: ['bank', 'cash', 'item'],
                            }),
                            s(`FeatureRewards.${k}.moneyItem`, 'text', 'black_money', 'the money item'),
                            s(`FeatureRewards.${k}.items`, 'json', [], 'items per payment'),
                        ]),
                    ],
                },
            ],
        },
    ],
    changed: 1,
    pending: 0,
    invalid: 0,
    total: 14,
    // the plain groups of the Simple view
    groups: [
        { key: 'tablet', title: 'Tablet', help: 'How officers open the tablet.', sections: ['tablet_and_commands'] },
        { key: 'missions', title: 'Missions and Builder', help: 'Mission ranges.', sections: ['blocks'] },
        { key: 'pay', title: 'Pay and cash', help: 'What officers are paid.', sections: ['limits_and_cash'] },
        { key: 'server', title: 'Server', help: 'Logs and language.', sections: ['general'] },
    ],
    common: ['Debug', 'Locale', 'Tablet.deskDistance'],
    // Settings -> Features (modules/settings Play.features); Spawning.enabled is not in this list, so it is left out
    features: [
        { key: 'spawning', play: 'npc', path: 'Spawning.enabled', risky: true },
        // limits: RealPlayers.liveCrime.maxLiveRuns is not in this list either, so only the unit size is linked
        {
            key: 'live_crimes',
            play: 'pvp',
            path: 'RealPlayers.liveCrime.enabled',
            risky: true,
            limits: ['Limits.maxUnitSize', 'RealPlayers.liveCrime.maxLiveRuns'],
        },
        { key: 'live_cash', play: 'pvp', path: 'RealPlayers.liveCrime.cash' },
    ],
    // the gear of each screen (modules/settings Play.screens); a section the data does not have is left out
    screens: {
        admin_home: ['general', 'tablet_and_commands'],
        admin_markers: ['map_markers'],
        admin_rs: ['real_players'],
        admin_restrictions: ['tablet_and_commands', 'mission_controls', 'real_players'],
        admin_money: ['limits_and_cash', 'feature_rewards', 'gone_section'],
        admin_departments: ['departments'],
    },
    // Settings -> Presets (Config.AdminUi.presets)
    presets: [
        { key: 'casual', name: 'Casual', help: 'Easier, friendlier play.', count: 2 },
        { key: 'golive', name: 'Go-live', help: 'Ready for players.', count: 2 },
        { key: 'broken', name: 'Broken', help: '', count: 1 },
    ],
};

// the preset rows (the server checks each one; 'broken' names a setting a preset may not set)
const PRESET_ROWS: Record<string, { path: string; value: unknown }[]> = {
    casual: [
        { path: 'Markers.route', value: false },
        { path: 'Limits.maxUnitSize', value: 8 },
    ],
    golive: [
        { path: 'Debug', value: false },
        { path: 'Tablet.title', value: 'Crimson-Police' },
    ],
    broken: [{ path: 'RealPlayers.liveCrime.cash', value: true }],
};

const history: SettingsHistoryRow[] = [
    {
        id: 1,
        path: 'Tablet.deskDistance',
        label: 'Desk distance',
        action: 'settingChanged',
        old: 3,
        oldSaved: false,
        new: 4.5,
        newSaved: true,
        oldValue: '3',
        newValue: '4.5',
        by: 'ABC12345',
        byName: 'John Doe',
        createdAt: now() - 600,
        latest: true,
        canRevert: true,
    },
];

function find(path: string): SettingView | undefined {
    for (const sec of data.sections)
        for (const g of sec.groups) for (const x of g.settings) if (x.path === path) return x;
    return undefined;
}

function reply(list: SettingView[]): SettingsReply {
    return { settings: list, health: [], pending: 0 };
}

registerMock('request', 'admin:getSettings', (): SettingsData => data);

function presetPreview(key: string): PresetPreview {
    const rows = PRESET_ROWS[key];
    if (!rows) throw new Error('err.preset_unknown');
    const out: PresetPreview = {
        key,
        name: data.presets?.find(p => p.key === key)?.name ?? key,
        changes: [],
        same: 0,
        refused: [],
    };
    for (const r of rows) {
        const x = find(r.path);
        if (!x || x.money || r.path === 'RealPlayers.liveCrime.cash')
            out.refused.push({ path: r.path, error: 'err.preset_path' });
        else if (JSON.stringify(x.value) === JSON.stringify(r.value)) out.same += 1;
        else out.changes.push({ path: r.path, label: x.label, from: x.value, fromSet: x.isSet, to: r.value });
    }
    return out;
}

registerMock('request', 'admin:previewPreset', (a: unknown) =>
    presetPreview(((a ?? {}) as { preset?: string }).preset ?? ''),
);

registerMock('action', 'server:admin:applyPreset', (p: unknown): SettingsReply => {
    const view = presetPreview(((p ?? {}) as { preset?: string }).preset ?? '');
    if (view.refused.length) throw new Error('err.preset_invalid');
    const out: SettingView[] = [];
    for (const c of view.changes) {
        const x = find(c.path);
        if (!x) continue;
        x.value = c.to;
        x.isSet = true;
        x.changed = JSON.stringify(x.value) !== JSON.stringify(x.default);
        out.push(x);
    }
    return { ...reply(out), preset: { key: view.key, changed: out.length } };
});

// Settings -> a setting that reloads the missions: the missions the new value would break (Missions.trial). The
// unit size limit below a mission's minimum unit breaks it; any other value breaks none.
const UNIT_MINIMUM = [
    { id: 'armored_escort', label: 'Armored Truck Escort', min: 4 },
    { id: 'bank_job', label: 'Bank Job', min: 3 },
    { id: 'gang_shootout', label: 'Gang Shootout', min: 2 },
];
registerMock('request', 'admin:trialMissions', (p: unknown) => {
    const patch = ((p ?? {}) as { patch?: { path?: string; value?: unknown; none?: boolean }[] }).patch ?? [];
    const failed: { id: string; label: string; error: string }[] = [];
    for (const c of patch) {
        if (c.path !== 'Limits.maxUnitSize' || c.none || typeof c.value !== 'number') continue;
        for (const m of UNIT_MINIMUM)
            if (m.min > c.value)
                failed.push({
                    id: m.id,
                    label: m.label,
                    error: `minOfficers ${m.min} is above Limits.maxUnitSize ${c.value}`,
                });
    }
    return { checked: 19, failed };
});

registerMock('action', 'server:admin:setSetting', (p: unknown): SettingsReply => {
    const { path, value, json, none } = (p ?? {}) as { path?: string; value?: unknown; json?: string; none?: boolean };
    const x = path ? find(path) : undefined;
    if (!x) throw new Error('err.setting_unknown');
    const v = json !== undefined ? JSON.parse(json) : value;
    x.value = none ? undefined : v;
    x.isSet = !none;
    x.changed = JSON.stringify(x.value) !== JSON.stringify(x.default);
    for (const h of history) if (h.path === x.path) h.latest = false;
    history.unshift({
        id: history.length + 1,
        path: x.path,
        label: x.label,
        action: 'settingChanged',
        oldSaved: false,
        new: x.value,
        newSaved: true,
        newValue: JSON.stringify(x.value),
        by: 'ABC12345',
        byName: 'John Doe',
        createdAt: now(),
        latest: true,
        canRevert: true,
    });
    return reply([x]);
});

registerMock('action', 'server:admin:resetSetting', (p: unknown): SettingsReply => {
    const x = find(((p ?? {}) as { path?: string }).path ?? '');
    if (!x) throw new Error('err.setting_unknown');
    x.value = x.default;
    x.isSet = x.defaultSet;
    x.changed = false;
    return reply([x]);
});

registerMock('action', 'server:admin:resetAllSettings', (): SettingsReply => {
    const out: SettingView[] = [];
    for (const sec of data.sections)
        for (const g of sec.groups)
            for (const x of g.settings)
                if (x.changed) {
                    x.value = x.default;
                    x.changed = false;
                    out.push(x);
                }
    // like the server, Reset all answers with the whole view
    return { ...reply(out), view: data };
});

registerMock('request', 'admin:getSettingsHistory', (): SettingsHistory => ({
    rows: history,
    page: 1,
    pages: 1,
    total: history.length,
}));

registerMock('action', 'server:admin:revertSetting', (p: unknown) => {
    const { historyId, again } = (p ?? {}) as { historyId?: number; again?: boolean };
    const h = history.find(r => r.id === historyId);
    if (!h) throw new Error('err.history_unknown');
    if (!h.latest && !again) throw new Error('err.setting_changed_since');
    const x = find(h.path);
    if (x) {
        x.value = h.oldSaved ? h.old : x.default;
        x.changed = h.oldSaved;
    }
    return reply(x ? [x] : []);
});

registerMock('request', 'admin:exportSettings', () => {
    const settings = data.sections
        .flatMap(sec => sec.groups.flatMap(g => g.settings))
        .filter(x => x.changed)
        .map(x => ({ path: x.path, value: x.value }));
    return { text: JSON.stringify({ kind: 'crimson-police-settings', settings }), count: settings.length };
});

registerMock('request', 'admin:previewSettingsImport', (a: unknown) => {
    const { text } = (a ?? {}) as { text?: string };
    const doc = JSON.parse(text ?? '{}') as { settings?: { path: string; value: unknown }[] };
    const changes = (doc.settings ?? [])
        .filter(c => find(c.path))
        .map(c => ({
            path: c.path,
            label: find(c.path)?.label ?? c.path,
            old: JSON.stringify(find(c.path)?.value),
            new: JSON.stringify(c.value),
        }));
    const unknown = (doc.settings ?? []).filter(c => !find(c.path)).map(c => c.path);
    return {
        changes,
        unknown,
        locked: [],
        invalid: [],
        money: [],
        unchanged: 0,
        previewToken: 'mock-import',
        expiresAt: now() + 120,
    };
});

registerMock('action', 'server:admin:importSettings', () => ({ imported: 1 }));

// ============================================================================
//                        MISSION AND LOCATION SWITCHES
// ============================================================================

const switches = new Map<string, MissionSwitchView>();

// The switches of a mission for the admin:getMissions mock (kept between requests).
export function missionSwitch(id: string, locations: number, offByDefault: boolean): MissionSwitchView {
    let sw = switches.get(id);
    if (!sw) {
        sw = {
            on: !offByDefault,
            defaultOn: !offByDefault,
            changed: false,
            locationsOff: 0,
            locations: Array.from({ length: Math.max(0, locations) }, (_, i) => ({
                index: i + 1,
                label: `Location ${i + 1}`,
                on: true,
                defaultOn: true,
            })),
        };
        switches.set(id, sw);
    }
    return sw;
}

function refresh(sw: MissionSwitchView): MissionSwitchView {
    sw.locationsOff = sw.locations.filter(l => !l.on).length;
    sw.changed = sw.on !== sw.defaultOn || sw.locations.some(l => l.on !== l.defaultOn);
    return sw;
}

registerMock('action', 'server:admin:setMissionEnabled', (p: unknown) => {
    const { missionId, enabled } = (p ?? {}) as { missionId?: string; enabled?: boolean };
    const sw = missionId ? switches.get(missionId) : undefined;
    if (!sw) throw new Error('err.unknown_mission');
    sw.on = !!enabled;
    return refresh(sw);
});

registerMock('action', 'server:admin:setLocationEnabled', (p: unknown) => {
    const { missionId, index, enabled } = (p ?? {}) as { missionId?: string; index?: number; enabled?: boolean };
    const sw = missionId ? switches.get(missionId) : undefined;
    const loc = sw?.locations.find(l => l.index === index);
    if (!sw || !loc) throw new Error('err.invalid_location');
    loc.on = !!enabled;
    return refresh(sw);
});

registerMock('action', 'server:admin:resetMissionSwitches', (p: unknown) => {
    const sw = switches.get(((p ?? {}) as { missionId?: string }).missionId ?? '');
    if (!sw) throw new Error('err.unknown_mission');
    sw.on = sw.defaultOn;
    sw.locations.forEach(l => {
        l.on = l.defaultOn;
    });
    return refresh(sw);
});
