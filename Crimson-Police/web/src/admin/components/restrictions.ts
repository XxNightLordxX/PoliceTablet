// The one restrictions list (Admin UI -> Restrictions, Supervisor UI -> Department -> Restrictions): the action every
// lift and extend goes through, its payloads, the read of each scope and the kind filter. types/restrictions.ts has
// the data.

import type { RestrictionKind, RestrictionKindInfo, RestrictionRow } from '../../types/restrictions';

export const RESTRICTION_ACTION = 'server:restriction';

// The read of each scope: the Admin UI's every kind, or the supervisor's department.
export function restrictionsRead(scope: 'admin' | 'sup'): string {
    return scope === 'sup' ? 'sup:getRestrictions' : 'admin:getRestrictions';
}

// Whether a row offers Lift: the admin's right for the kind, or (a supervisor) the row's own canLift.
export function rowCanLift(
    row: Pick<RestrictionRow, 'canLift'>,
    kind: Pick<RestrictionKindInfo, 'canLift'> | undefined,
    scope: 'admin' | 'sup',
): boolean {
    if (scope === 'sup') return row.canLift === true && kind?.canLift === true;
    return kind?.canLift === true;
}

// The kinds in the filter's order.
export const RESTRICTION_KINDS: RestrictionKind[] = [
    'suspension',
    'missionBan',
    'pairBlock',
    'exclusion',
    'rsSuspension',
    'volunteerBlock',
];

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
