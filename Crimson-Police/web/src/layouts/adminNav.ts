// The Admin UI layout: plain screen names, the sidebar under six groups (NPC missions, Player vs police, Police
// teamwork, Permissions, Economy, System) each with a one-line description, the rarely used tools under More, a search
// box over the screens (and the settings), and a breadcrumb.

import type { ScreenKey } from '../shared/navigation';
export type AdminGroup = 'npc' | 'pvp' | 'team' | 'permissions' | 'economy' | 'system';

// The groups in sidebar order (title ui.nav.admin_group.<key>, one-line description ui.nav.admin_hint.<key>).
// (Rewards was a group of its own before the Money screen took in Payouts and Rewards: Money is under Economy.)
export const ADMIN_GROUPS: AdminGroup[] = ['npc', 'pvp', 'team', 'permissions', 'economy', 'system'];

// The group each Admin screen is listed under (Home has none: it stays on top).
export const ADMIN_GROUP_OF: Record<string, AdminGroup> = {
    admin_missions: 'npc',
    admin_live: 'npc',
    admin_markers: 'npc',
    admin_rs: 'pvp',
    admin_officers: 'team',
    admin_departments: 'team',
    admin_seasons: 'team',
    admin_leaderboards: 'team',
    admin_permissions: 'permissions',
    admin_money: 'economy',
    admin_settings: 'system',
    admin_system: 'system',
    admin_audit: 'system',
    admin_testing: 'system',
};

// The rarely used tools, folded under More.
export const ADMIN_RARE = ['admin_seasons', 'admin_leaderboards', 'admin_departments', 'admin_audit', 'admin_testing'];

// The pseudo item the search list ends with: Settings opened with the typed words in its search box.
export const SETTINGS_SEARCH = '__settings_search';

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

// The screens whose words match the typed text: each item's label, its other names and its group's title, in
// sidebar order. Empty text = none (the sidebar shows as usual).
export function searchScreens<T extends { key: string; words: string[] }>(items: T[], text: string): T[] {
    const q = text.trim().toLowerCase();
    if (!q) return [];
    const parts = q.split(/\s+/);
    return items.filter(it => {
        const hay = it.words.join(' ').toLowerCase();
        return parts.every(p => hay.includes(p));
    });
}

// The breadcrumb over a screen: Home > group > screen (none on Home itself).
export function adminCrumbs(key: ScreenKey | string): { home: boolean; group?: AdminGroup } {
    if (key === 'admin_home') return { home: false };
    return { home: true, group: ADMIN_GROUP_OF[key] };
}
