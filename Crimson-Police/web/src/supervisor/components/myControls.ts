// Department → Controls, inline use (MG3; the 'Your controls today' card before): one row per Mission control the
// supervisor may use now, with its current value, the admin's limits and today's use. Pure functions, checked by
// supHead.walk.ts; the server (sup:getMyControls) decides which controls are listed. Always shown (no switch).

import type { MyControl } from '../../types/oversight';

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

// The controls used from their own dialogs (Give points, Mission ban, notices ...): no row on Controls of their own,
// so their limits and today's use are listed in one card.
export function actionControlRows(rows: MyControlRow[]): MyControlRow[] {
    return rows.filter(r => r.action);
}
