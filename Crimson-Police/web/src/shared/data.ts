// Defensive helpers for data coming from Lua. Lua tables cannot hold nil, and an empty Lua table may be encoded as {}
// instead of [], so lists from the server can arrive as objects or be missing entirely. Wrap every list you .map()
// with asArray().

import type { HudState, RunResult, Session } from './types';

// The value when it is an array, otherwise [].
export function asArray<T>(v: T[] | null | undefined | Record<string, never>): T[] {
    return Array.isArray(v) ? v : [];
}

// The value when it is a finite number, otherwise undefined (optional numeric extras).
function optionalNumber(v: unknown): number | undefined {
    return typeof v === 'number' && isFinite(v) ? v : undefined;
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

// When a countdown value arrived: kept while a patch repeats the same value (Lua sends the full merged state), so a
// HUD mounted later (the Officer UI closed) counts on from it instead of from the stale value.
function arrivedAt(same: boolean, prev: number | undefined): number {
    return same && prev !== undefined ? prev : Date.now();
}

// What is left of a countdown of `seconds` that arrived at receivedAt.
export function secondsSince(seconds: number, receivedAt?: number): number {
    if (receivedAt === undefined) return seconds;
    return Math.max(0, seconds - Math.floor((Date.now() - receivedAt) / 1000));
}

// HudState with nullable fields as null and objectives as an array. prev is the HUD state on screen.
export function normalizeHud(h: HudState, prev?: HudState | null): HudState {
    const same = !!prev && prev.runId === h.runId;
    const timer = h.timer ?? null;
    const pt = same ? prev.timer : null;
    const route = h.route
        ? { ...h.route, secondsLeft: h.route.secondsLeft ?? null, distance: h.route.distance ?? null }
        : null;
    const pr = same ? prev.route : null;
    return {
        ...h,
        test: !!h.test,
        modifier: h.modifier ?? null,
        timer: timer
            ? {
                  ...timer,
                  receivedAt: arrivedAt(
                      !!pt && pt.remaining === timer.remaining && pt.paused === timer.paused,
                      pt?.receivedAt,
                  ),
              }
            : null,
        route: route
            ? {
                  ...route,
                  receivedAt: arrivedAt(
                      !!pr && pr.status === route.status && pr.secondsLeft === route.secondsLeft,
                      pr?.receivedAt,
                  ),
              }
            : null,
        objectives: asArray(h.objectives),
        detail: h.detail ?? null,
        message: h.message ?? null,
        testControls: !!h.testControls,
    };
}

// The points cap (whole points) and the multipliers of a breakdown. A row stored before CP.Scoring.compute sent them
// was worked out with the shipped defaults (Config.Scoring.scoreCap 2, Config.Events.todMultiplier 2).
export function pointsLimits(p: RunResult['points']): { cap: number; scoreCap: number; todMultiplier: number } {
    const scoreCap = p.scoreCap ?? 2;
    return { cap: p.cap ?? Math.floor(p.P * scoreCap + 1e-9), scoreCap, todMultiplier: p.todMultiplier ?? 2 };
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
            cap: optionalNumber(p.cap),
            scoreCap: optionalNumber(p.scoreCap),
            todMultiplier: optionalNumber(p.todMultiplier),
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
