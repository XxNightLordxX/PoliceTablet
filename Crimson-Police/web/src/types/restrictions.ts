// Admin UI · Restrictions (screen key 'admin_restrictions'): what modules/supervisor/restrictions.lua answers.
// Callback (openAdmin key): admin:getRestrictions -> RestrictionsData. Action (a reason): server:admin:restriction
// { op: 'lift' | 'extend', kind, citizenid, other?, hours?, reason } (hours 1 to the kind's maxHours).

// suspension = a tablet suspension, missionBan = a supervisor's mission ban, pairBlock / exclusion / rsSuspension =
// the Real suspects tools, volunteerBlock = a volunteer's strikes block.
export type RestrictionKind =
    'suspension' | 'missionBan' | 'pairBlock' | 'exclusion' | 'rsSuspension' | 'volunteerBlock';

export interface RestrictionRow {
    kind: RestrictionKind;
    citizenid: string;
    name?: string | null;
    // the second player of a pair block (the suspect)
    other?: string | null;
    otherName?: string | null;
    untilAt: number;
    by?: string | null;
    byName?: string | null;
    reason?: string | null;
    dept?: string | null;
    // set by the strikes, not by a person
    auto?: boolean;
}

export interface RestrictionKindInfo {
    key: RestrictionKind;
    maxHours: number;
    canLift: boolean;
    canExtend: boolean;
}

export interface RestrictionsData {
    kinds: RestrictionKindInfo[];
    rows: RestrictionRow[];
    serverTime: number;
}
