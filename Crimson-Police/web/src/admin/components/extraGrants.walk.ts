// Admin UI -> Permissions -> Extra grants against the browser mocks (node walk.mjs, a gate step): the
// grantable powers and the saved grants from admin:getPermissions, and the helpers that build the setting
// Permissions.grants one change at a time.

import '../../mocks/oversight.mock';
import { request } from '../../shared/nui';
import type { PermissionsData } from '../../types/oversight';
import { CID_PATTERN, cleanGrant, grantCount, withCitizenid, withPower, withRule } from './extraGrants';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    const res = await request<PermissionsData>('admin:getPermissions', {});
    const extra = res.data?.extra;
    const keys = (extra?.powers ?? []).map(p => p.key);
    ok(keys.includes('missionControls') && keys.includes('fieldTraining'), 'the powers list the grantable ones');
    ok(!keys.includes('bulkVoid') && !keys.includes('openAdmin'), 'never an admin-only action');
    ok(extra?.powers.find(p => p.key === 'breakEditLock')?.on === false, 'a power switched off shows off');
    ok(grantCount(extra?.grants?.reviewFlagged) === 2, 'review: one department and one citizenid');
    ok(extra?.gangs[0]?.key === 'ballas' && extra.gangs[0].grades.length === 4, 'the Qbox gangs with their grades');

    // one department's rule, then a gang's, then a citizenid, then everything removed again
    let g = withRule(undefined, 'departments', 'sast', { minGrade: 3 });
    ok(grantCount(g) === 1 && g.departments?.sast?.minGrade === 3, 'a department from a grade');
    g = withRule(g, 'gangs', 'ballas', { grades: [2, 3] });
    g = withCitizenid(g, ' abc123 ', true);
    ok(grantCount(g) === 3 && g.citizenids?.[0] === 'ABC123', 'a gang and a citizenid (trimmed, upper case)');
    g = withCitizenid(g, 'ABC123', true);
    ok(g.citizenids?.length === 1, 'a citizenid once');
    const all = withPower(extra?.grants, 'missionControls', g);
    ok(all.missionControls && all.reviewFlagged && all.builderTeleport, 'the other powers stay as they were');
    g = withRule(
        withRule(withCitizenid(g, 'ABC123', false), 'gangs', 'ballas', undefined),
        'departments',
        'sast',
        undefined,
    );
    ok(cleanGrant(g) === undefined, 'nothing left: no grant');
    ok(withPower(all, 'missionControls', g).missionControls === undefined, 'and the power leaves the map');
    ok(CID_PATTERN.test('ABC12345') && !CID_PATTERN.test('bad id!') && !CID_PATTERN.test(''), 'a citizenid pattern');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
