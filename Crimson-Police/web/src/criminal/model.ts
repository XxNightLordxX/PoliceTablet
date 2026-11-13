// The criminal tablet's logic without React: normalising the server's view, the sidebar with its badges
// and the texts that depend on the view. criminal.walk.ts checks it against the mocks.

import type { CrimActive, CrimHistoryRow, CrimRole, CrimScreen, CrimView } from '../types/criminal';

export const CRIM_SCREENS: CrimScreen[] = ['home', 'jobs', 'active', 'history', 'rules'];
const ROLES: CrimRole[] = ['runner', 'driver', 'fugitive'];

function num(v: unknown, d = 0): number {
    const n = Number(v);
    return Number.isFinite(n) ? n : d;
}

function list<T>(v: unknown): T[] {
    // an empty Lua table comes as {} (no array): treat any non-array as empty
    return Array.isArray(v) ? (v as T[]) : [];
}

function roles(v: unknown): CrimRole[] {
    return list<string>(v).filter((r): r is CrimRole => (ROLES as string[]).includes(r));
}

// The view as the server sent it, with every list a list and every number a number.
export function normalizeCrimView(raw: unknown): CrimView | null {
    if (!raw || typeof raw !== 'object') return null;
    const v = raw as Partial<CrimView> & Record<string, unknown>;
    const s = (v.status ?? {}) as Partial<CrimView['status']>;
    const r = (v.rules ?? {}) as Partial<CrimView['rules']>;
    return {
        now: num(v.now, Math.floor(Date.now() / 1000)),
        volunteersOn: v.volunteersOn === true,
        name: typeof v.name === 'string' ? v.name : null,
        status: {
            listed: s.listed === true,
            untilAt: s.untilAt ?? null,
            roles: roles(s.roles),
            allRoles: roles(s.allRoles).length ? roles(s.allRoles) : ROLES,
            canJoin: s.canJoin === true,
            why: s.why ?? null,
            blockedUntil: s.blockedUntil ?? null,
        },
        jobs: list<CrimView['jobs'][number]>(v.jobs).filter(j => j && typeof j.token === 'string'),
        active: v.active && typeof v.active === 'object' ? (v.active as CrimActive) : null,
        history: list<CrimHistoryRow>(v.history),
        strikes: list<number>(v.strikes).map(x => num(x)),
        rules: {
            windowMinutes: num(r.windowMinutes, 60),
            strikes: num(r.strikes, 3),
            strikeHours: num(r.strikeHours, 24),
            blockHours: num(r.blockHours, 24),
            askSeconds: num(r.askSeconds, 30),
            travelMinutes: num(r.travelMinutes, 5),
            cancelGraceSeconds: num(r.cancelGraceSeconds, 60),
        },
    };
}

// The sidebar badge of a screen: the open question, the suspect he plays, the strikes that count.
export function badgeOf(view: CrimView | null, screen: CrimScreen): string | null {
    if (!view) return null;
    if (screen === 'jobs' && view.jobs.length > 0) return String(view.jobs.length);
    if (screen === 'active' && view.active) return '!';
    if (screen === 'history' && view.strikes.length > 0) return String(view.strikes.length);
    return null;
}

// The screen to land on: what Lua asked for, else the case he plays, else an open question, else Home.
export function landingOf(view: CrimView | null, asked?: string | null): CrimScreen {
    if (asked && (CRIM_SCREENS as string[]).includes(asked)) return asked as CrimScreen;
    if (view?.active) return 'active';
    if (view && view.jobs.length > 0) return 'jobs';
    return 'home';
}

// Minutes left of a window that ends at untilAt (os.time()), never below 0.
export function minutesLeft(untilAt: number | null | undefined, now: number): number {
    if (!untilAt) return 0;
    return Math.max(0, Math.ceil((untilAt - now) / 60));
}

// Hours left until an os.time(), at least 1 while it is in the future.
export function hoursLeft(at: number | null | undefined, now: number): number {
    if (!at || at <= now) return 0;
    return Math.max(1, Math.ceil((at - now) / 3600));
}

// The locale key of a History row's outcome: a dropout wins (it was a strike), else how it ended for him.
export function outcomeKey(row: CrimHistoryRow): string {
    if (row.dropout) return `crimtab.outcome.dropout_${row.dropout}`;
    const o = row.outcome ?? 'got_away';
    return `crimtab.outcome.${['detained', 'booked', 'got_away', 'left', 'void', 'stopped'].includes(o) ? o : 'got_away'}`;
}

// Whether he can still pick roles (at least one ticked).
// What giving up the case now costs: the free line while the free give-up lasts (graceLeft: the live countdown, or
// null for the view's own snapshot), else the strike line. Active shows it, and Home next to "Get off the list"
// while a case runs, because stopping gives the case up too.
export function cancelKey(active: CrimActive, graceLeft: number | null | undefined): string {
    const left = graceLeft === undefined ? (active.graceLeft ?? null) : graceLeft;
    return active.freeCancel && (left === null || left > 0)
        ? 'crimtab.active.cancel_free'
        : 'crimtab.active.cancel_strike';
}

export function rolesPayload(picked: Record<string, boolean>): CrimRole[] {
    return ROLES.filter(r => picked[r]);
}
