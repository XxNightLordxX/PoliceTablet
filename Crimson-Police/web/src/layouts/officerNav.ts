// The Officer UI sidebar order: Config.Tablet.sidebarOrder ('classic' = the registry order, as before;
// 'mostUsed' = the screens an officer opens most first) and Config.Tablet.activeFirst (Active Mission right under Home
// while on a run). Only the order changes: the same screens show, a hidden one stays hidden.

import type { Session } from '../shared/types';

export type OfficerNav = { order: 'classic' | 'mostUsed'; activeFirst: boolean; compact: boolean };

export const CLASSIC_NAV: OfficerNav = { order: 'classic', activeFirst: false, compact: false };

// 'mostUsed': the common path first (find a mission, run it, take a call, form a unit), then the officer's own record
const MOST_USED = ['home', 'board', 'active', 'dispatch', 'unit', 'me', 'options'];

// The session's sidebar settings; an older session or an unknown value = as before.
export function officerNavOf(session: Session | null | undefined): OfficerNav {
    const n = session?.config?.officerNav;
    if (!n || typeof n !== 'object') return CLASSIC_NAV;
    return {
        order: n.order === 'mostUsed' ? 'mostUsed' : 'classic',
        activeFirst: n.activeFirst === true,
        compact: n.compact === true,
    };
}

// The screens in sidebar order. A key the order does not name keeps its registry place after the named ones.
export function orderOfficerScreens<T extends { key: string }>(screens: T[], nav: OfficerNav, onRun: boolean): T[] {
    let list = screens.slice();
    if (nav.order === 'mostUsed') {
        const rank = (k: string) => {
            const i = MOST_USED.indexOf(k);
            return i < 0 ? MOST_USED.length : i;
        };
        list = list
            .map((s, i) => ({ s, i }))
            .sort((a, b) => rank(a.s.key) - rank(b.s.key) || a.i - b.i)
            .map(x => x.s);
    }
    if (nav.activeFirst && onRun) {
        const at = list.findIndex(s => s.key === 'active');
        if (at >= 0) {
            const [active] = list.splice(at, 1);
            const home = list.findIndex(s => s.key === 'home');
            list.splice(home >= 0 ? home + 1 : 0, 0, active);
        }
    }
    return list;
}
