// Defensive helpers for data coming from Lua. Lua tables cannot hold nil, and an empty Lua table may be encoded as {}
// instead of [], so lists from the server can arrive as objects or be missing entirely. Wrap every list you .map()
// with asArray().

import type { HudState, RunResult, Session } from './types';

// The value when it is an array, otherwise [].
export function asArray<T>(v: T[] | null | undefined | Record<string, never>): T[] {
    return Array.isArray(v) ? v : [];
}

// Session with list fields guaranteed to be arrays.
export function normalizeSession(s: Session): Session {
    const cfg = (s.config ?? {}) as Partial<Session['config']>;
    return {
        ...s,
        roles: { officer: !!s.roles?.officer, supervisor: !!s.roles?.supervisor, admin: !!s.roles?.admin },
        officer: s.officer ?? null,
        logo: s.logo ?? null,
        actions: asArray(s.actions),
        locale: s.locale && typeof s.locale === 'object' ? s.locale : {},
        config: {
            missionTypes: asArray(cfg.missionTypes),
            departments: asArray(cfg.departments),
            tiers: asArray(cfg.tiers),
            maxRecalcs: Number(cfg.maxRecalcs ?? 0),
            disputeWindowHours: Number(cfg.disputeWindowHours ?? 0),
            periods: asArray(cfg.periods),
            filters: asArray(cfg.filters),
        },
    };
}

// HudState with nullable fields as null and objectives as an array.
export function normalizeHud(h: HudState): HudState {
    return {
        ...h,
        test: !!h.test,
        modifier: h.modifier ?? null,
        timer: h.timer ?? null,
        route: h.route
            ? { ...h.route, secondsLeft: h.route.secondsLeft ?? null, distance: h.route.distance ?? null }
            : null,
        objectives: asArray(h.objectives),
        detail: h.detail ?? null,
        message: h.message ?? null,
        testControls: !!h.testControls,
    };
}

// RunResult with bonus/penalty lists as arrays and nullable fields as null.
export function normalizeResult(r: RunResult): RunResult {
    const p = (r.points ?? {}) as Partial<RunResult['points']>;
    return {
        ...r,
        test: !!r.test,
        points: {
            P: Number(p.P ?? 0),
            bonuses: asArray(p.bonuses),
            penalties: asArray(p.penalties),
            subtotal: Number(p.subtotal ?? 0),
            mTeam: Number(p.mTeam ?? 1),
            mCross: Number(p.mCross ?? 1),
            mStreak: Number(p.mStreak ?? 1),
            capped: !!p.capped,
            tod: !!p.tod,
            failedShare: p.failedShare ?? null,
            final: Number(p.final ?? 0),
        },
        cash: {
            B: Number(r.cash?.B ?? 0),
            mTier: Number(r.cash?.mTier ?? 1),
            mMod: Number(r.cash?.mMod ?? 1),
            amount: Number(r.cash?.amount ?? 0),
            status: r.cash?.status ?? 'none',
        },
        flagged: r.flagged ?? null,
    };
}
