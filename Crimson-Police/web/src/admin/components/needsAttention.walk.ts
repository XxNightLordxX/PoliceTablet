// Admin UI -> Home's Needs attention panel (step H5) against the browser mocks (node walk.mjs, a gate step): the
// one batched admin:getNeedsAttention answer, its lines and the screen each one opens, and the plain screen titles.

import '../../mocks/admin_system.mock';
import { adminNavOf, adminTitleKey } from '../../layouts/adminNav';
import { request } from '../../shared/nui';
import type { Session } from '../../shared/types';
import type { NeedsAttentionData } from '../../types/admin_system';
import { attentionLines, attentionWaiting } from './needsAttention';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    const res = await request<NeedsAttentionData>('admin:getNeedsAttention', {});
    ok(res.ok && res.data, 'admin:getNeedsAttention answers');
    const lines = attentionLines(res.data);
    ok(lines.map(l => l.key).join(',') === 'problems,refused,disputes,flagged,rs', 'five lines in order');
    const by = Object.fromEntries(lines.map(l => [l.key, l]));
    ok(by.problems?.screen === 'admin_system' && by.problems.params?.tab === 'problems', 'Problems opens its tab');
    ok(by.refused?.screen === 'admin_live' && by.refused.params?.tab === 'refused', 'refused: Live -> Refused');
    ok(by.disputes?.screen === 'admin_officers' && by.disputes.params?.tab === 'disputes', 'Officers -> Disputes');
    ok(by.flagged?.screen === 'admin_leaderboards' && by.flagged.n === 3, 'flagged runs: Leaderboards, the count');
    ok(by.rs?.screen === 'admin_rs' && by.rs.n === 0, 'open player suspect cases: Player suspects');
    ok(attentionWaiting(lines) === 3, 'three lines have something waiting');

    // no Player suspects screen: no such line; bad numbers count as 0; no answer: no lines
    const noRs = attentionLines({ problems: -1, refusedToday: 1.7, disputes: Number.NaN, flagged: 0, rsCases: null });
    ok(noRs.length === 4 && !noRs.some(l => l.key === 'rs'), 'no Player suspects screen: four lines');
    ok(noRs[0]?.n === 0 && noRs[1]?.n === 1 && noRs[2]?.n === 0, 'counts are whole and never below 0');
    ok(attentionWaiting(noRs) === 1 && attentionLines(undefined).length === 0, 'waiting count; no answer, no lines');

    // the title inside a screen: the plain name in the plain layout, else the screen's own name
    const plain = adminNavOf({ config: { adminUi: { plainLayout: true } } } as unknown as Session);
    const classic = adminNavOf({ config: { adminUi: {} } } as unknown as Session);
    ok(adminTitleKey('admin_live', plain) === 'ui.nav.plain.admin_live', 'plain layout: the plain title');
    ok(adminTitleKey('admin_live', classic) === 'ui.screen.admin_live', 'shipped: the title as before');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
