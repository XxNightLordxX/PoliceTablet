// Mock: Admin UI -> Restrictions and Supervisor UI -> Department -> Restrictions (modules/supervisor/restrictions.lua).

// Mock: Admin UI -> Restrictions and Supervisor UI -> Department -> Restrictions (modules/supervisor/restrictions.lua).
// Each kind registers its rows and its lift and extend here from its own mock file (admin_live: missionBan, admin_rs:
// the Real suspects kinds); suspensions live here. A kind open to supervisors also registers his side
// (registerRestrictionSup: boards.mock's mission bans of the supervisor). Two reads and one action, like the server.

import { registerMock } from '../shared/nui';
import type { RestrictionKind, RestrictionRow, RestrictionsData } from '../types/restrictions';

export interface MockRestrictionKind {
    maxHours: number;
    rows: () => Omit<RestrictionRow, 'kind'>[];
    lift: (p: MockRestrictionPayload) => unknown;
    extend?: (p: MockRestrictionPayload, hours: number) => unknown;
}

export interface MockRestrictionPayload {
    op?: string;
    kind?: string;
    citizenid?: string;
    other?: string;
    hours?: number;
    reason?: string;
}

const kinds = new Map<RestrictionKind, MockRestrictionKind>();
const ORDER: RestrictionKind[] = [
    'suspension',
    'missionBan',
    'pairBlock',
    'exclusion',
    'rsSuspension',
    'volunteerBlock',
];

export function registerRestrictionKind(key: RestrictionKind, def: MockRestrictionKind): void {
    kinds.set(key, def);
}

// The supervisor's side of a kind: the rows of his department (canLift on his own) and his lift.
export interface MockRestrictionSup {
    rows: () => RestrictionRow[];
    lift: (p: MockRestrictionPayload & { activityOf?: string }) => unknown;
}
const supKinds = new Map<RestrictionKind, MockRestrictionSup>();

export function registerRestrictionSup(key: RestrictionKind, def: MockRestrictionSup): void {
    supKinds.set(key, def);
}

const nowS = () => Math.floor(Date.now() / 1000);

// a suspended officer (the Officers screen sets and lifts these with server:admin:suspend)
const suspensions: Omit<RestrictionRow, 'kind'>[] = [
    {
        citizenid: 'OFF00004',
        name: 'Tom Late',
        untilAt: nowS() + 3 * 86400,
        by: 'ADM00002',
        byName: 'Admin Two',
        reason: 'Repeated no-shows',
        dept: 'lspd',
    },
    {
        citizenid: 'OFF00011',
        name: 'Sam Field',
        untilAt: nowS() + 86400,
        by: 'ADM00002',
        byName: 'Admin Two',
        reason: 'Left a scene',
        dept: 'sast',
    },
];

registerRestrictionKind('suspension', {
    maxHours: 3650 * 24,
    rows: () => suspensions,
    lift: p => {
        const i = suspensions.findIndex(s => s.citizenid === p.citizenid && s.untilAt > nowS());
        if (i < 0) throw new Error('err.not_suspended');
        suspensions.splice(i, 1);
        return { citizenid: p.citizenid, days: 0 };
    },
    extend: (p, hours) => {
        const s = suspensions.find(r => r.citizenid === p.citizenid && r.untilAt > nowS());
        if (!s) throw new Error('err.not_suspended');
        s.untilAt += hours * 3600;
        return { citizenid: p.citizenid, untilTs: s.untilAt };
    },
});

registerMock('request', 'admin:getRestrictions', (): RestrictionsData => {
    const now = nowS();
    const rows: RestrictionRow[] = [];
    const list = [];
    for (const key of ORDER) {
        const def = kinds.get(key);
        if (!def) continue;
        list.push({ key, maxHours: def.maxHours, canLift: true, canExtend: !!def.extend });
        for (const r of def.rows()) if (r.untilAt > now) rows.push({ ...r, kind: key });
    }
    rows.sort((a, b) => a.untilAt - b.untilAt);
    return { kinds: list, rows, serverTime: now };
});

registerMock('request', 'sup:getRestrictions', (): RestrictionsData => {
    const now = nowS();
    const rows: RestrictionRow[] = [];
    const list = [];
    for (const key of ORDER) {
        const sup = supKinds.get(key);
        if (!sup) continue;
        list.push({ key, maxHours: kinds.get(key)?.maxHours ?? 24, canLift: true, canExtend: false });
        for (const r of sup.rows()) if (r.untilAt > now) rows.push({ ...r, kind: key });
    }
    rows.push(
        ...suspensions
            .filter(r => r.dept === 'sast' && r.untilAt > now)
            .map(r => ({ ...r, kind: 'suspension' as const, canLift: false })),
    );
    list.push({ key: 'suspension' as const, maxHours: 3650 * 24, canLift: false, canExtend: false });
    rows.sort((a, b) => a.untilAt - b.untilAt);
    return { kinds: list, rows, dept: 'sast', serverTime: now };
});

registerMock('action', 'server:restriction', (p: MockRestrictionPayload & { activityOf?: string }) => {
    // a supervisor's lift of his own row (the officer dialog sends activityOf; his tab lists it with canLift)
    const sup = supKinds.get(p.kind as RestrictionKind);
    if (sup && p.op === 'lift' && sup.rows().some(r => r.citizenid === p.citizenid && r.canLift)) {
        if (!p.reason || !p.reason.trim()) throw new Error('err.reason_required');
        return sup.lift(p);
    }
    const def = kinds.get(p.kind as RestrictionKind);
    if (!def) throw new Error('err.restriction_kind');
    if (p.op !== 'lift' && p.op !== 'extend') throw new Error('err.restriction_op');
    if (!p.reason || !p.reason.trim()) throw new Error('err.reason_required');
    if (p.citizenid === 'ADM00001' || p.other === 'ADM00001') throw new Error('err.self_target');
    if (p.op === 'lift') return def.lift(p);
    if (!def.extend) throw new Error('err.no_permission');
    const hours = Number(p.hours);
    if (!Number.isInteger(hours) || hours < 1 || hours > def.maxHours) throw new Error('err.restriction_hours');
    return def.extend(p, hours);
});
