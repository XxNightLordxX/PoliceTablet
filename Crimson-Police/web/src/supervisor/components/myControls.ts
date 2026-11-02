// The Department Report's 'Your controls today' card (Config.Tablet.supervisorControlsCard): one row per
// Mission control the supervisor may use now, with its current value, the admin's limits and today's use. Pure
// functions, checked by myControls.walk.ts; the server (sup:getMyControls) decides which controls are listed.

import type { Session } from '../../shared/types';
import type { MyControl } from '../../types/oversight';

// The card shows only with Config.Tablet.supervisorControlsCard = true (an older session: no card, as before).
export function controlsCardOn(session: Session | null | undefined): boolean {
    return session?.config?.supervisorNav?.controlsCard === true;
}

// today: 'none' = no day count; 'left' = uses left; 'used' = every use of today is spent.
export interface MyControlRow {
    key: string;
    // an action (give points, mission ban, notices ...) has no value of its own: it is used from its screen
    action: boolean;
    changed: boolean;
    limits: { min: number; max: number } | null;
    today: 'none' | 'left' | 'used';
    used: number;
    perDay: number;
}

function num(v: unknown): number | null {
    return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

export function myControlRow(c: MyControl): MyControlRow {
    const min = num(c.min);
    const max = num(c.max);
    const perDay = num(c.perDay) ?? 0;
    const used = Math.max(0, num(c.usedToday) ?? 0);
    return {
        key: c.key,
        action: c.kind === 'action',
        changed: c.changed === true,
        limits: min !== null && max !== null ? { min, max } : null,
        today: perDay <= 0 ? 'none' : used >= perDay ? 'used' : 'left',
        used,
        perDay,
    };
}

// Controls with a day count first (most used up first), then the rest in the server's order.
export function myControlRows(list: MyControl[] | null | undefined): MyControlRow[] {
    const rows = (Array.isArray(list) ? list : []).filter(c => c && typeof c.key === 'string').map(myControlRow);
    const share = (r: MyControlRow) => (r.today === 'none' ? -1 : r.used / r.perDay);
    return rows
        .map((r, i) => ({ r, i }))
        .sort((a, b) => share(b.r) - share(a.r) || a.i - b.i)
        .map(x => x.r);
}
