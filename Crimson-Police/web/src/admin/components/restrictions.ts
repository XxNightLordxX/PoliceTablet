// The one restrictions list (Admin UI -> Restrictions): the action every lift and extend goes through, its payloads,
// the kind filter and the Real suspects tools' rows as restrictions. types/restrictions.ts has the data.

import type { RsAdminRow } from '../../types/admin_rs';
import type { RestrictionKind, RestrictionRow } from '../../types/restrictions';

export const RESTRICTION_ACTION = 'server:admin:restriction';

// The kinds in the filter's order.
export const RESTRICTION_KINDS: RestrictionKind[] = [
    'suspension',
    'missionBan',
    'pairBlock',
    'exclusion',
    'rsSuspension',
    'volunteerBlock',
];

// A Real suspects tool's kind as a restriction kind.
const RS_KIND: Record<RsAdminRow['kind'], RestrictionKind> = {
    block: 'pairBlock',
    exclude: 'exclusion',
    suspend: 'rsSuspension',
};

// The row a Real suspects admin row is in the restrictions list: the officer first (a block's suspect is other),
// the player alone for an exclusion.
export function rsRestriction(row: RsAdminRow): Pick<RestrictionRow, 'kind' | 'citizenid' | 'other'> {
    const kind = RS_KIND[row.kind];
    if (row.kind === 'exclude') return { kind, citizenid: row.suspect ?? '' };
    if (row.kind === 'suspend') return { kind, citizenid: row.officer ?? '' };
    return { kind, citizenid: row.officer ?? '', other: row.suspect ?? '' };
}

// The payload of one step on one row: lift (any kind) or extend by hours, with the reason.
export function restrictionPayload(
    op: 'lift' | 'extend',
    row: Pick<RestrictionRow, 'kind' | 'citizenid' | 'other'>,
    reason: string,
    hours?: number,
): Record<string, unknown> {
    const out: Record<string, unknown> = { op, kind: row.kind, citizenid: row.citizenid, reason: reason.trim() };
    if (row.other) out.other = row.other;
    if (op === 'extend') out.hours = hours;
    return out;
}

// The rows of one kind ('all' keeps every row).
export function rowsOfKind(rows: RestrictionRow[], kind: RestrictionKind | 'all'): RestrictionRow[] {
    return kind === 'all' ? rows : rows.filter(r => r.kind === kind);
}

// Hours to extend by: a whole number from 1 to the kind's longest, else null.
export function extendHours(v: unknown, maxHours: number): number | null {
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1 || n > maxHours) return null;
    return n;
}
