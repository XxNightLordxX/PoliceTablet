// The Admin UI plain layout (Config.AdminUi.plainLayout): plain screen names, the sidebar under seven groups
// (NPC missions, Player vs police, Police teamwork, Rewards, Permissions, Economy, System) each with a one-line
// description, the rarely used tools under More, a search box over the screens (and the settings), and a breadcrumb.

// The Admin UI plain layout (Config.AdminUi.plainLayout): plain screen names, the sidebar under seven groups
// (NPC missions, Player vs police, Police teamwork, Rewards, Permissions, Economy, System) each with a one-line
// description, the rarely used tools under More, a search box over the screens (and the settings), and a breadcrumb.
// Only the layout changes: the same screens show, a hidden one stays hidden, screen keys and links stay the same.

import type { ScreenKey } from '../shared/navigation';
import type { Session } from '../shared/types';

export type AdminNav = { plain: boolean };
export type AdminGroup = 'npc' | 'pvp' | 'team' | 'rewards' | 'permissions' | 'economy' | 'system';

export const CLASSIC_ADMIN_NAV: AdminNav = { plain: false };

// The groups in sidebar order (title ui.nav.admin_group.<key>, one-line description ui.nav.admin_hint.<key>).
export const ADMIN_GROUPS: AdminGroup[] = ['npc', 'pvp', 'team', 'rewards', 'permissions', 'economy', 'system'];

// The group each Admin screen is listed under in the plain layout (Home has none: it stays on top).
export const ADMIN_GROUP_OF: Record<string, AdminGroup> = {
    admin_missions: 'npc',
    admin_live: 'npc',
    admin_markers: 'npc',
    admin_rs: 'pvp',
    admin_officers: 'team',
    admin_departments: 'team',
    admin_seasons: 'team',
    admin_leaderboards: 'team',
    admin_payouts: 'rewards',
    admin_rewards: 'rewards',
    admin_permissions: 'permissions',
    admin_payments: 'economy',
    admin_money: 'economy',
    admin_settings: 'system',
    admin_system: 'system',
    admin_audit: 'system',
    admin_testing: 'system',
};

// The rarely used tools, folded under More in the plain layout.
export const ADMIN_RARE = ['admin_seasons', 'admin_leaderboards', 'admin_departments', 'admin_audit', 'admin_testing'];

// The pseudo item the search list ends with: Settings opened with the typed words in its search box.
export const SETTINGS_SEARCH = '__settings_search';

// The session's Admin UI layout; an older session or anything but true = as before.
export function adminNavOf(session: Session | null | undefined): AdminNav {
    return session?.config?.adminUi?.plainLayout === true ? { plain: true } : CLASSIC_ADMIN_NAV;
}

// The locale key of a screen's sidebar label and title: its plain name in the plain layout, else ui.screen.<key>.
export function adminTitleKey(key: string, nav: AdminNav): string {
    return nav.plain ? `ui.nav.plain.${key}` : `ui.screen.${key}`;
}

// A screen's group in the plain layout (undefined = on top, or the plain layout is off).
export function adminGroupOf(key: string, nav: AdminNav): AdminGroup | undefined {
    return nav.plain ? ADMIN_GROUP_OF[key] : undefined;
}

// A screen's sidebar fold in the plain layout ('more' = a rarely used tool); off, the registry's own group.
export function adminFoldOf(key: string, nav: AdminNav, own?: 'main' | 'more'): 'main' | 'more' | undefined {
    return nav.plain ? (ADMIN_RARE.includes(key) ? 'more' : 'main') : own;
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

// The breadcrumb over a screen in the plain layout: Home > group > screen (Home alone for Home itself).
export function adminCrumbs(key: ScreenKey | string, nav: AdminNav): { home: boolean; group?: AdminGroup } {
    if (!nav.plain || key === 'admin_home') return { home: false };
    return { home: true, group: ADMIN_GROUP_OF[key] };
}
