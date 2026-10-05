// Browser mocks for Admin UI → Settings and the mission switches (a small sample of the real list).

import { registerMock } from '../shared/nui';
import type {
    MissionSwitchView,
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

const data: SettingsData = {
    sections: [
        {
            key: 'general',
            title: 'General',
            file: 'config',
            changed: 0,
            count: 2,
            groups: [
                {
                    path: '',
                    label: '',
                    desc: '',
                    settings: [
                        s('Debug', 'boolean', false, 'true = each module prints tagged debug lines'),
                        s('Locale', 'enum', 'en', '', { options: ['en'], restart: true }),
                    ],
                },
            ],
        },
        {
            key: 'tablet_and_commands',
            title: 'Tablet and commands',
            file: 'config',
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
            key: 'blocks',
            title: 'Mission Builder ranges (blocks.lua)',
            file: 'blocks',
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
    ],
    changed: 1,
    pending: 0,
    invalid: 0,
    total: 10,
};

const history: SettingsHistoryRow[] = [
    {
        id: 1,
        actor: 'ABC12345',
        actorName: 'John Doe',
        role: 'admin',
        action: 'settingChanged',
        target: 'Tablet.deskDistance',
        oldValue: '3',
        newValue: '4.5',
        createdAt: now() - 600,
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

registerMock('action', 'server:admin:setSetting', (p: unknown): SettingsReply => {
    const { path, value, json, none } = (p ?? {}) as { path?: string; value?: unknown; json?: string; none?: boolean };
    const x = path ? find(path) : undefined;
    if (!x) throw new Error('err.setting_unknown');
    const v = json !== undefined ? JSON.parse(json) : value;
    x.value = none ? undefined : v;
    x.isSet = !none;
    x.changed = JSON.stringify(x.value) !== JSON.stringify(x.default);
    history.unshift({
        id: history.length + 1,
        actor: 'ABC12345',
        actorName: 'John Doe',
        role: 'admin',
        action: 'settingChanged',
        target: x.path,
        newValue: JSON.stringify(x.value),
        createdAt: now(),
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
    return reply(out);
});

registerMock('request', 'admin:getSettingsHistory', (): SettingsHistory => ({
    rows: history,
    page: 1,
    pages: 1,
    total: history.length,
}));

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
