// The one Review queue against the browser mocks (node walk.mjs, a gate step, FM3): review:getQueue lists flagged

// The one Review queue against the browser mocks (node walk.mjs, a gate step, FM3): review:getQueue lists flagged
// runs and disputes in one list with a type, the filter keeps one type, server:review:decide decides both types and
// answers with the fresh queue, the Admin UI's queue (all) also lists disputes about failed runs, and the old
// screens' callbacks are gone from the screens.

import '../../mocks/core.mock';
import '../../mocks/oversight.mock';
import oversight from '../../../../locales/parts/oversight.json';
import uiLocale from '../../../../locales/parts/ui.json';
import { action, request } from '../../shared/nui';
import type { ReviewQueueData } from '../../types/oversight';
import panelSrc from './ReviewQueuePanel.tsx?raw';
import supSrc from '../screens/ReviewQueue.tsx?raw';
import adminSrc from '../../admin/screens/Review.tsx?raw';
import type { RunHistoryData } from '../../types/oversight';
import historySrc from './RunHistory.tsx?raw';
import {
    batchesOf,
    countsOf,
    decidePayload,
    decisionsOf,
    historyKey,
    itemKey,
    itemsOf,
    runRowsOf,
    showOf,
    undoPayload,
} from './reviewQueue';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps() {
    const sup = await request<ReviewQueueData>('review:getQueue', {});
    const items = sup.data?.items ?? [];
    const counts = countsOf(items);
    ok(counts.flag > 0 && counts.dispute > 0, 'one list holds flagged runs and disputes');
    ok(counts.all === items.length && counts.flag + counts.dispute === counts.all, 'the counts add up');
    ok(
        itemsOf(items, 'flag').every(i => i.type === 'flag'),
        'the filter keeps flagged runs',
    );
    ok(
        itemsOf(items, 'dispute').every(i => i.type === 'dispute'),
        'the filter keeps disputes',
    );
    ok(itemsOf(items, 'all').length === items.length, 'All shows everything');
    ok(new Set(items.map(itemKey)).size === items.length, 'every item has its own key across both types');
    ok(showOf('dispute') === 'dispute' && showOf('x') === 'all', 'a link picks the filter');
    const flag = items.find(i => i.type === 'flag');
    const dispute = items.find(i => i.type === 'dispute');
    ok(flag && decisionsOf(flag).join() === 'approve,void', 'a flag is approved or voided');
    ok(dispute && decisionsOf(dispute).join() === 'approve,reject', 'a dispute is approved or rejected');
    ok(flag && runRowsOf(items, flag).length >= 1 && dispute && runRowsOf(items, dispute).length === 0, 'run rows');
    ok(!items.some(i => i.type === 'dispute' && i.kind === 'failed'), 'supervisors never see failed-run disputes');

    const all = await request<ReviewQueueData>('review:getQueue', { all: true });
    ok(all.data?.all === true, 'the Admin UI asks for every department');
    if (flag) {
        const res = await action<{ queue?: ReviewQueueData }>(
            'server:review:decide',
            decidePayload(flag, 'approve', 'Checked'),
        );
        ok(res.ok && !res.data?.queue?.items.some(i => itemKey(i) === itemKey(flag)), 'a decided flag leaves');
    }
    if (dispute) {
        const res = await action<{ queue?: ReviewQueueData }>(
            'server:review:decide',
            decidePayload(dispute, 'reject', 'Fine', true),
        );
        ok(res.ok && res.data?.queue?.all === true, 'a dispute decision answers with the admin queue');
    }
    const bad = await action('server:review:decide', { type: 'other', id: 1, decision: 'approve', reason: 'x' });
    ok(!bad.ok, 'an unknown type is refused');

    const o = oversight as Record<string, string>;
    // FIN4: the admin's queue lists the correction batches with their Undo, and a void made there can be undone
    const aq = await request<ReviewQueueData>('review:getQueue', { all: true });
    const aItems = aq.data?.items ?? [];
    const batch = batchesOf(aItems, 'all')[0];
    ok(batch && batch.type === 'batch' && aq.data?.canUndoBatch === true, "the admin's queue lists a batch with Undo");
    ok(batchesOf(aItems, 'flag').length === 0 && itemsOf(aItems, 'batch').length === 0, 'the filters keep them apart');
    ok(countsOf(aItems).batch === batchesOf(aItems, 'all').length && showOf('batch') === 'batch', 'counted, linkable');
    ok(batchesOf(items, 'all').length === 0 && sup.data?.canUndo !== true, "a supervisor's queue: no batches, no Undo");
    if (batch) {
        const res = await action<{ queue?: ReviewQueueData }>(
            'server:review:decide',
            undoPayload('batch', batch.id, 'Wrong filter'),
        );
        ok(res.ok && !batchesOf(res.data?.queue?.items, 'all').some(b => b.id === batch.id), 'Undo takes the batch');
    }
    const toVoid = itemsOf(aItems, 'flag')[0];
    if (toVoid && toVoid.type === 'flag') {
        const v = await action('server:review:decide', decidePayload(toVoid, 'void', 'Teleport', true));
        ok(v.ok && aq.data?.canUndo === true, 'an admin voids a run in the queue, Undo offered');
        const u = await action('server:review:decide', undoPayload('flag', toVoid.id, 'My mistake'));
        ok(u.ok, 'Undo restores it');
        ok(!(await action('server:review:decide', undoPayload('flag', toVoid.id, 'Again'))).ok, 'once');
        const h = await request<RunHistoryData>('review:getRunHistory', { runUuid: toVoid.runUuid });
        const ev = h.data?.events ?? [];
        ok(ev.length > 0 && ev.every((e, i) => i === 0 || ev[i - 1].at <= e.at), 'History: one timeline, oldest first');
        ok(
            ev.every(e => o[historyKey(e)] !== undefined || historyKey(e).startsWith('sup.history.action.')),
            'keys',
        );
    }
    ok(
        panelSrc.includes('<RunHistoryDialog') && historySrc.includes("'review:getRunHistory'"),
        'History opens one run',
    );
    for (const k of ['flag', 'note', 'decision', 'dispute', 'batch', 'row']) {
        ok(o[`sup.history.kind.${k}`] !== undefined, `the ${k} kind has a label`);
    }
    for (const a of [
        'approveFlagged',
        'voidFlagged',
        'voidPending',
        'voidRun',
        'restoreRun',
        'disputeApproved',
        'disputeRejected',
        'voidKindSet',
        'flagManual',
        'other',
    ]) {
        ok(o[`sup.history.action.${a}`] !== undefined, `the ${a} line has a text`);
    }

    for (const src of [panelSrc, supSrc, adminSrc]) {
        ok(
            !/sup:getReviewQueue|admin:getFlagged|admin:getDisputes|:handleDispute|:reviewFlagged|approveRun'/.test(
                src,
            ),
            'no old names',
        );
    }
    ok(panelSrc.includes("'review:getQueue'") && panelSrc.includes("'server:review:decide'"), 'one read, one action');
    ok(adminSrc.includes('<ReviewQueuePanel') && supSrc.includes('<ReviewQueuePanel'), 'both UIs use the one queue');
    const u = uiLocale as Record<string, string>;
    for (const k of ['sup.review.tab.queue', 'sup.review.col.type', 'sup.review.show_all', 'sup.review.empty_title']) {
        ok(typeof o[k] === 'string' && o[k].length > 0, `${k} has a line`);
    }
    ok(typeof u['admin.review.tab.queue'] === 'string', 'admin.review.tab.queue has a line');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
