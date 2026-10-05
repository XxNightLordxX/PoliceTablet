// Sidebar badges: the NavCounts of getNavCounts, kept fresh by the 'nav' push (the server sends one after every push
// that can change a count).

import { usePush, useRequest } from '../shared/hooks';
import type { ScreenKey } from '../shared/navigation';
import type { NavCounts } from '../shared/types';

export const EMPTY_COUNTS: NavCounts = { invites: 0, calls: 0, review: 0, commendations: 0, rewards: 0, onRun: false };

// The server sends 'nav' pushes to a tablet that asked within 10 minutes: an open tablet asks again before that.
const REASK_MS = 5 * 60 * 1000;

export function useNavCounts(enabled = true): NavCounts {
    const { data, setData } = useRequest<NavCounts>('getNavCounts', {}, { skip: !enabled, pollMs: REASK_MS });
    usePush<NavCounts | null>(enabled ? 'nav' : null, next => {
        if (next && typeof next === 'object') setData({ ...EMPTY_COUNTS, ...next });
    });
    return data ? { ...EMPTY_COUNTS, ...data } : EMPTY_COUNTS;
}

function countBadge(n: number): string | undefined {
    if (!n || n <= 0) return undefined;
    return n > 99 ? '99+' : String(n);
}

// The badge (a count) or live dot of one sidebar item.
export function navBadge(key: ScreenKey, c: NavCounts): { badge?: string; live?: boolean } {
    switch (key) {
        case 'home':
            return { badge: countBadge(c.rewards) };
        case 'dispatch':
            return { badge: countBadge(c.calls) };
        case 'unit':
            return { badge: countBadge(c.invites) };
        case 'active':
            return { live: c.onRun === true };
        case 'profile':
            return { badge: countBadge(c.commendations) };
        case 'sup_review':
            return { badge: countBadge(c.review) };
        // Admin UI (admin-only counts: the server sends them to admin players only)
        case 'admin_officers':
            return { badge: countBadge((c.adminReview ?? 0) + (c.adminDisputes ?? 0)) };
        case 'admin_payments':
            return { badge: countBadge(c.adminPayments ?? 0) };
        case 'admin_live':
            return { badge: countBadge(c.adminLive ?? 0) };
        default:
            return {};
    }
}
