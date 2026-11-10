// Admin UI · Restrictions walked against the browser mocks (node walk.mjs, a gate step): one list of every kind
// running now (a suspension, a mission ban, the Real suspects rows), each extended or lifted through the one action
// with a reason, and the screen sits in the People group.

import '../../mocks/restrictions.mock';
import '../../mocks/admin_live.mock';
import '../../mocks/admin_rs.mock';
import { ADMIN_GROUP_OF } from '../../layouts/adminNav';
import { ADMIN_SCREENS } from '../../layouts/screens';
import { action, request } from '../../shared/nui';
import type { RestrictionsData } from '../../types/restrictions';
import { RESTRICTION_ACTION, extendHours, restrictionPayload, rowsOfKind, rsRestriction } from './restrictions';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function refused(p: Promise<unknown>): Promise<string> {
    try {
        const res = (await p) as { ok?: boolean; error?: string } | undefined;
        if (res && res.ok === false) return res.error ?? 'refused';
        return '';
    } catch (e) {
        return e instanceof Error ? e.message : String(e);
    }
}

async function steps(): Promise<void> {
    ok(
        ADMIN_SCREENS.some(s => s.key === 'admin_restrictions'),
        'the Admin UI has a Restrictions screen',
    );
    ok(ADMIN_GROUP_OF.admin_restrictions === 'people', 'in the People group');

    const res = await request<RestrictionsData>('admin:getRestrictions', {});
    const rows = res.data?.rows ?? [];
    const kinds = new Set(rows.map(r => r.kind));
    ok(kinds.has('suspension') && kinds.has('missionBan'), 'suspensions and mission bans in one list');
    ok(kinds.has('pairBlock') || kinds.has('exclusion') || kinds.has('rsSuspension'), 'and the Real suspects rows');
    ok(
        rows.every((r, i) => i === 0 || rows[i - 1].untilAt <= r.untilAt),
        'the soonest end first',
    );
    ok(
        rowsOfKind(rows, 'missionBan').every(r => r.kind === 'missionBan'),
        'the kind filter keeps one kind',
    );
    ok(rowsOfKind(rows, 'all').length === rows.length, 'All keeps every row');

    const ban = rows.find(r => r.kind === 'missionBan');
    ok(ban && ban.byName && ban.reason, 'a row says who set it and why');
    if (ban) {
        const max = res.data?.kinds.find(k => k.key === 'missionBan')?.maxHours ?? 0;
        ok(max === 168 && extendHours(169, max) === null && extendHours(2, max) === 2, 'extend stays within a week');
        const ext = restrictionPayload('extend', ban, ' Again ', 2);
        ok(
            JSON.stringify(ext) ===
                `{"op":"extend","kind":"missionBan","citizenid":"${ban.citizenid}","reason":"Again","hours":2}`,
            'extend sends the kind, the citizenid, the hours and the trimmed reason',
        );
        ok((await refused(action(RESTRICTION_ACTION, { ...ext, reason: '' }))) === 'err.reason_required', 'a reason');
        ok((await action(RESTRICTION_ACTION, ext)).ok, 'the ban is extended');
        const after = await request<RestrictionsData>('admin:getRestrictions', {});
        const ban2 = (after.data?.rows ?? []).find(r => r.kind === 'missionBan');
        ok(ban2 && ban2.untilAt === ban.untilAt + 7200, 'by two hours');
        ok((await action(RESTRICTION_ACTION, restrictionPayload('lift', ban, 'Appeal'))).ok, 'and lifted');
        const gone = await request<RestrictionsData>('admin:getRestrictions', {});
        ok(!(gone.data?.rows ?? []).some(r => r.kind === 'missionBan'), 'and is gone');
    }
    ok(
        (await refused(action(RESTRICTION_ACTION, { op: 'lift', kind: 'nope', citizenid: 'X', reason: 'r' }))) ===
            'err.restriction_kind',
        'an unknown kind is refused',
    );
    const rs = rsRestriction({ kind: 'suspend', officer: 'OFF00001', untilAt: 0 });
    ok(rs.kind === 'rsSuspension' && rs.citizenid === 'OFF00001' && rs.other === undefined, 'a Real suspects row maps');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
