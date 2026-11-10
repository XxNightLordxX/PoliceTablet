// The Admin UI layout, organised by job: Home on top, then People, Missions, Real players, Money, Review and System,
// each with a one-line description, the rarely used tools under More, and a breadcrumb. The search box (Ctrl+K) jumps
// to any screen or tab, officer, mission or setting (globalResults).

import type { AdminScreenKey, ScreenKey, ScreenParams } from '../shared/navigation';
export type AdminGroup = 'people' | 'missions' | 'players' | 'money' | 'review' | 'system';

// The groups in sidebar order (title ui.nav.admin_group.<key>, one-line description ui.nav.admin_hint.<key>). A group
// whose screens are all hidden is not shown (Real players while live crimes and volunteers are off).
export const ADMIN_GROUPS: AdminGroup[] = ['people', 'missions', 'players', 'money', 'review', 'system'];

// The group each Admin screen is listed under (Home has none: it stays on top).
export const ADMIN_GROUP_OF: Record<string, AdminGroup> = {
    admin_officers: 'people',
    admin_restrictions: 'people',
    admin_departments: 'people',
    admin_permissions: 'people',
    admin_leaderboards: 'people',
    admin_seasons: 'people',
    admin_missions: 'missions',
    admin_live: 'missions',
    admin_markers: 'missions',
    admin_testing: 'missions',
    admin_rs: 'players',
    admin_money: 'money',
    admin_review: 'review',
    admin_audit: 'review',
    admin_settings: 'system',
    admin_system: 'system',
};

// The rarely used tools, folded under More.
export const ADMIN_RARE = ['admin_seasons', 'admin_leaderboards'];

// The locale key of a screen's sidebar label and title: its plain name.
export function adminTitleKey(key: string): string {
    return `ui.nav.plain.${key}`;
}

// A screen's group (undefined = on top: Home).
export function adminGroupOf(key: string): AdminGroup | undefined {
    return ADMIN_GROUP_OF[key];
}

// A screen's sidebar fold ('more' = a rarely used tool).
export function adminFoldOf(key: string): 'main' | 'more' {
    return ADMIN_RARE.includes(key) ? 'more' : 'main';
}

// The tabs the search jumps to: the screen, the params that open the tab and the tab's label (a locale key).
export interface AdminJump {
    screen: AdminScreenKey;
    params: ScreenParams;
    label: string;
}

export const ADMIN_JUMPS: AdminJump[] = [
    { screen: 'admin_missions', params: { tab: 'catalog' }, label: 'admin.missions.tab.catalog' },
    { screen: 'admin_missions', params: { tab: 'builder' }, label: 'admin.missions.tab.builder' },
    { screen: 'admin_missions', params: { tab: 'operation' }, label: 'admin.missions.tab.operation' },
    { screen: 'admin_missions', params: { tab: 'dispatch' }, label: 'mc.admin.tab' },
    { screen: 'admin_missions', params: { tab: 'history' }, label: 'admin.missions.tab.history' },
    { screen: 'admin_missions', params: { tab: 'stats' }, label: 'admin.missions.tab.stats' },
    { screen: 'admin_live', params: { tab: 'runs' }, label: 'admin.live.tab.runs' },
    { screen: 'admin_live', params: { tab: 'units' }, label: 'admin.live.tab.units' },
    { screen: 'admin_live', params: { tab: 'refused' }, label: 'admin.live.tab.refused' },
    { screen: 'admin_rs', params: { tab: 'cases' }, label: 'rs.ui.cases' },
    { screen: 'admin_rs', params: { tab: 'pairs' }, label: 'rs.ui.pairs_tab' },
    { screen: 'admin_rs', params: { tab: 'volunteers' }, label: 'rs.ui.volunteers' },
    { screen: 'admin_money', params: { moneyTab: 'pay' }, label: 'admin.money.tab.pay' },
    { screen: 'admin_money', params: { moneyTab: 'rewards' }, label: 'admin.money.tab.rewards' },
    { screen: 'admin_money', params: { moneyTab: 'payments' }, label: 'admin.money.tab.payments' },
    { screen: 'admin_money', params: { moneyTab: 'funds' }, label: 'admin.money.tab.funds' },
    { screen: 'admin_review', params: { tab: 'queue' }, label: 'admin.review.tab.queue' },
    { screen: 'admin_review', params: { tab: 'queue', show: 'flag' }, label: 'admin.review.tab.flagged' },
    { screen: 'admin_review', params: { tab: 'profiles' }, label: 'admin.review.tab.profiles' },
    { screen: 'admin_review', params: { tab: 'queue', show: 'dispute' }, label: 'admin.review.tab.disputes' },
    { screen: 'admin_review', params: { tab: 'corrections' }, label: 'admin.review.tab.corrections' },
    { screen: 'admin_settings', params: { tab: 'presets' }, label: 'settings.tab.presets' },
    { screen: 'admin_settings', params: { tab: 'features' }, label: 'settings.tab.features' },
    { screen: 'admin_settings', params: { tab: 'history' }, label: 'settings.tab.history' },
    { screen: 'admin_system', params: { tab: 'storage' }, label: 'sysadmin.ui.tab.storage' },
    { screen: 'admin_system', params: { tab: 'backups' }, label: 'sysadmin.ui.tab.backups' },
    { screen: 'admin_system', params: { tab: 'webhooks' }, label: 'sysadmin.ui.tab.webhooks' },
    { screen: 'admin_system', params: { tab: 'problems' }, label: 'sysadmin.ui.tab.problems' },
    { screen: 'admin_system', params: { tab: 'integrations' }, label: 'sysadmin.ui.tab.integrations' },
    { screen: 'admin_system', params: { tab: 'cleanup' }, label: 'sysadmin.ui.tab.cleanup' },
];

// True when every typed word is in the words (any case). Empty text = no match.
export function wordsMatch(words: string[], text: string): boolean {
    const q = text.trim().toLowerCase();
    if (!q) return false;
    const hay = words.join(' ').toLowerCase();
    return q.split(/\s+/).every(p => hay.includes(p));
}

// What the search finds, in the order listed: screens and tabs, then officers, missions and settings.
export type FoundKind = 'screens' | 'officers' | 'missions' | 'settings';
export const FOUND_KINDS: FoundKind[] = ['screens', 'officers', 'missions', 'settings'];
// How many of each kind are listed at most.
export const FOUND_MAX: Record<FoundKind, number> = { screens: 8, officers: 5, missions: 5, settings: 6 };
// The last line: Settings opened with the typed words in its own search box.
export const SETTINGS_SEARCH = 'settings:*';

export interface FoundItem {
    // unique in the list: '<kind>:<id>'
    key: string;
    kind: FoundKind;
    label: string;
    screen: AdminScreenKey;
    params?: ScreenParams;
}

export interface FoundSources {
    // the screens the admin may open, each with its words (its label first)
    screens: { key: string; words: string[] }[];
    // the tabs, each with its label (screen and tab) and its words, already translated
    jumps: { jump: AdminJump; label: string; words: string[] }[];
    officers?: { citizenid: string; name: string; callsign?: string | null; departmentShort?: string }[];
    missions?: { id: string; label: string; typeLabel?: string }[];
    settings?: { path: string; label: string }[];
}

// The search list for the typed text. A tab shows only while its screen does; officers come from the server's own
// search (already matched), missions and settings are matched here by their label and id or path.
export function globalResults(src: FoundSources, text: string): FoundItem[] {
    const typed = text.trim();
    if (!typed) return [];
    const open = new Set(src.screens.map(s => s.key));
    const out: FoundItem[] = [];
    const add = (kind: FoundKind, items: FoundItem[]) => out.push(...items.slice(0, FOUND_MAX[kind]));
    add('screens', [
        ...src.screens
            .filter(s => wordsMatch(s.words, typed))
            .map(s => ({
                key: `screens:${s.key}`,
                kind: 'screens' as const,
                label: s.words[0],
                screen: s.key as AdminScreenKey,
            })),
        ...src.jumps
            .filter(j => open.has(j.jump.screen) && wordsMatch(j.words, typed))
            .map(j => ({
                key: `screens:${j.jump.screen}:${JSON.stringify(j.jump.params)}`,
                kind: 'screens' as const,
                label: j.label,
                screen: j.jump.screen,
                params: j.jump.params,
            })),
    ]);
    if (open.has('admin_officers')) {
        add(
            'officers',
            (src.officers ?? []).map(o => ({
                key: `officers:${o.citizenid}`,
                kind: 'officers' as const,
                label: [o.callsign, o.name || o.citizenid, o.departmentShort].filter(Boolean).join(' · '),
                screen: 'admin_officers' as const,
                params: { citizenid: o.citizenid },
            })),
        );
    }
    if (open.has('admin_missions')) {
        add(
            'missions',
            (src.missions ?? [])
                .filter(m => wordsMatch([m.label, m.id, m.typeLabel ?? ''], typed))
                .map(m => ({
                    key: `missions:${m.id}`,
                    kind: 'missions' as const,
                    label: m.label || m.id,
                    screen: 'admin_missions' as const,
                    params: { tab: 'catalog', mission: m.id },
                })),
        );
    }
    if (open.has('admin_settings')) {
        add(
            'settings',
            (src.settings ?? [])
                .filter(s => wordsMatch([s.label, s.path], typed))
                .map(s => ({
                    key: `settings:${s.path}`,
                    kind: 'settings' as const,
                    label: s.label || s.path,
                    screen: 'admin_settings' as const,
                    params: { q: s.path },
                })),
        );
        out.push({ key: SETTINGS_SEARCH, kind: 'settings', label: '', screen: 'admin_settings', params: { q: typed } });
    }
    return out;
}

// Ctrl+K (or Cmd+K) puts the cursor in the search box.
export function isSearchKey(e: { key: string; ctrlKey?: boolean; metaKey?: boolean; altKey?: boolean }): boolean {
    return (e.ctrlKey === true || e.metaKey === true) && e.altKey !== true && e.key.toLowerCase() === 'k';
}

// The breadcrumb over a screen: Home > group > screen (none on Home itself).
// A screen has a gear (its own settings) while the admin may open Settings; Settings itself has none.
export function gearShown(key: ScreenKey | string, settingsShown: boolean): boolean {
    return settingsShown && key !== 'admin_settings' && key.startsWith('admin_');
}

export function adminCrumbs(key: ScreenKey | string): { home: boolean; group?: AdminGroup } {
    if (key === 'admin_home') return { home: false };
    return { home: true, group: ADMIN_GROUP_OF[key] };
}
