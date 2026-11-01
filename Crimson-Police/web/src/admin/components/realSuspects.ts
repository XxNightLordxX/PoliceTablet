// Admin UI · Real suspects (step V18): the screen's plain helpers (no React), walked by realSuspects.walk.ts.

import type { RsAdminRow, RsCaseLine, RsLedgerLine, RsPerson, RsSuspect, RsTool } from '../../types/admin_rs';

export const RS_DAYS_MAX = 3650;
export const RS_REASON_MAX = 255;

// The three tools, their server actions and the locale key of their success toast.
export const RS_TOOL_ACTION: Record<RsTool, string> = {
    block: 'server:admin:rsBlockPair',
    exclude: 'server:admin:rsExclude',
    suspend: 'server:admin:rsSuspend',
};

export type RsCaseFilter = 'all' | 'open' | 'flagged';

// A citizenid the server accepts (modules/opponents/staff: letters, digits, _ and -, at most 50).
export function validCid(v: unknown): v is string {
    return typeof v === 'string' && v.length > 0 && v.length <= 50 && /^[\w-]+$/.test(v);
}

// The cases a filter shows: 'open' = still running, 'flagged' = with a conduct flag or a suspect note.
export function filterCases(cases: RsCaseLine[], filter: RsCaseFilter): RsCaseLine[] {
    if (filter === 'open') return cases.filter(c => c.open);
    if (filter === 'flagged') return cases.filter(c => (c.flags || 0) + (c.notes || 0) > 0);
    return cases;
}

// "Name (CITIZENID)", the citizenid alone, or '-'.
export function personText(p: RsPerson | null | undefined): string {
    if (!p || !p.citizenid) return '-';
    return p.name ? `${p.name} (${p.citizenid})` : p.citizenid;
}

// Seconds from the case's open as "+m:ss" (nil = '-').
export function sinceOpen(seconds: number | null | undefined): string {
    if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return '-';
    const s = Math.max(0, Math.floor(seconds));
    return `+${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

// The suspect a damage-ledger line names (by his label in the case), or undefined.
export function ledgerSuspect(line: RsLedgerLine, suspects: RsSuspect[]): RsSuspect | undefined {
    return line.label ? suspects.find(s => s.label === line.label) : undefined;
}

// The running admin rows that name this citizenid (as officer or suspect).
export function rowsFor(rows: RsAdminRow[], cid: string): RsAdminRow[] {
    return rows.filter(r => r.officer === cid || r.suspect === cid);
}

export interface RsToolForm {
    tool: RsTool;
    officer: string;
    suspect: string;
    citizenid: string;
    days: number | null;
    reason: string;
}

// The action and payload a tool form sends, or the locale key of what is wrong with it (the server checks it all
// again: 0 < days <= 3650, a reason, never the admin's own characters).
export function toolRequest(
    form: RsToolForm,
): { ok: true; action: string; payload: Record<string, unknown> } | { ok: false; error: string } {
    const reason = form.reason.trim();
    const days = form.days;
    const officer = form.officer.trim();
    const suspect = form.suspect.trim();
    const cid = form.citizenid.trim();
    if (form.tool === 'block') {
        if (!validCid(officer) || !validCid(suspect)) return { ok: false, error: 'err.invalid_citizenid' };
        if (officer === suspect) return { ok: false, error: 'err.invalid_citizenid' };
    } else if (!validCid(cid)) {
        return { ok: false, error: 'err.invalid_citizenid' };
    }
    if (days === null || !Number.isFinite(days) || days <= 0 || days > RS_DAYS_MAX) {
        return { ok: false, error: 'err.invalid_days' };
    }
    if (reason === '') return { ok: false, error: 'rs.ui.tool.need_reason' };
    const payload: Record<string, unknown> =
        form.tool === 'block' ? { officer, suspect, days, reason } : { citizenid: cid, days, reason };
    return { ok: true, action: RS_TOOL_ACTION[form.tool], payload };
}
