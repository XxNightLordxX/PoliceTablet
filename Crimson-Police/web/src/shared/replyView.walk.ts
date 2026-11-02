// Smoother workflows against the browser mocks (node walk.mjs, a gate step): replies that carry the
// fresh view (Review Queue, Dispatch, Admin Backups) and the remembered supervisor dialog values.

// Smoother workflows against the browser mocks (node walk.mjs, a gate step): Approve / Void on the Review
// Queue and Decline on Dispatch answer with the screen's fresh view, so the screen needs no second request; a reply
// without it asks again. The supervisor dialogs open with the values last used only while
// Config.Tablet.supervisorRemember is on.

import '../mocks/oversight.mock';
import '../mocks/missioncalls.mock';
import '../mocks/admin_system.mock';
import { keepLastUsed, lastUsed, rememberOn, resetLastUsed, startNumber } from '../supervisor/components/lastUsed';
import type { BackupsData } from '../types/admin_system';
import type { DispatchView } from '../types/missioncalls';
import type { ReviewQueueData } from '../types/oversight';
import { action, request } from './nui';
import { applyReplyView, replyView } from './replyView';
import type { Session } from './types';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

async function steps(): Promise<void> {
    // the helper: a view in the reply is applied, none asks again
    let set: unknown = null;
    let asked = 0;
    ok(
        applyReplyView(
            { queue: { flagged: [] } },
            'queue',
            v => (set = v),
            () => (asked += 1),
        ),
        'a view is applied',
    );
    ok(set !== null && asked === 0, 'applied without a second request');
    ok(
        !applyReplyView(
            { rowId: 4 },
            'queue',
            v => (set = v),
            () => (asked += 1),
        ),
        'no view: not applied',
    );
    ok(asked === 1, 'no view: the screen asks again (an older server)');
    ok(replyView(null, 'queue') === null && replyView({ queue: 3 }, 'queue') === null, 'only an object is a view');

    // Review Queue: Approve answers with the queue, the row gone
    const before = await request<ReviewQueueData>('sup:getReviewQueue', {});
    const first = before.ok && before.data && Array.isArray(before.data.flagged) ? before.data.flagged[0] : undefined;
    ok(!!first, 'the mock queue lists a flagged run');
    if (first) {
        const res = await action('server:sup:reviewFlagged', {
            rowId: first.rowId,
            decision: 'approve',
            reason: 'Checked on camera',
        });
        const q = replyView<ReviewQueueData>(res.data, 'queue');
        ok(res.ok && !!q, 'Approve answers with the Review Queue');
        ok(!!q && Array.isArray(q.flagged) && !q.flagged.some(r => r.rowId === first.rowId), 'the row is gone from it');
    }
    const disputes = before.ok && before.data && Array.isArray(before.data.disputes) ? before.data.disputes : [];
    if (disputes[0]) {
        const res = await action('server:sup:handleDispute', {
            disputeId: disputes[0].id,
            decision: 'reject',
            reason: 'The run was fine',
        });
        ok(res.ok && !!replyView<ReviewQueueData>(res.data, 'queue'), 'a dispute answer carries the Review Queue');
    }

    // Dispatch: Decline answers with the view, the call gone
    const dv = await request<DispatchView>('getMissionCalls', {});
    const pushed = dv.ok && dv.data ? dv.data.calls.find(c => !!c.missionLabel) : undefined;
    ok(!!pushed, 'the mock Dispatch lists a pushed mission');
    if (pushed) {
        const res = await action('server:declineMissionCall', { callId: pushed.id });
        const v = replyView<DispatchView>(res.data, 'view');
        ok(res.ok && !!v, 'Decline answers with the Dispatch view');
        ok(!!v && !v.calls.some(c => c.id === pushed.id), 'the declined call is gone from it');
    }

    // Admin UI -> System -> Backups: Backup now and Delete answer with the fresh list
    const made = await action('server:admin:backupNow', {});
    const name = made.ok && made.data ? (made.data as { name?: string }).name : undefined;
    const list = replyView<BackupsData>(made.data, 'view');
    ok(
        made.ok && !!list && list.backups.some(b => b.name === name),
        'Backup now answers with the list, the new one in it',
    );
    if (name) {
        const del = await action('server:admin:deleteBackup', { name, reason: 'old', confirm: name });
        const after = replyView<BackupsData>(del.data, 'view');
        ok(del.ok && !!after && !after.backups.some(b => b.name === name), 'Delete answers with the list without it');
    }

    // Config.Tablet.supervisorRemember: off (as shipped) keeps nothing
    resetLastUsed();
    const off = {
        config: { supervisorNav: { byTask: false, compact: false, landing: 'first' } },
    } as unknown as Session;
    const on = {
        config: { supervisorNav: { byTask: false, compact: false, landing: 'first', remember: true } },
    } as unknown as Session;
    ok(!rememberOn(off) && rememberOn(on) && !rememberOn(null), 'remember follows the session');
    keepLastUsed('award', false, { number: 25, reason: 'Great stop' });
    ok(lastUsed('award', true).reason === undefined, 'off: nothing is kept');
    keepLastUsed('award', true, { number: 25, reason: '  Great stop  ' });
    ok(
        lastUsed('award', true).reason === 'Great stop' && lastUsed('award', true).number === 25,
        'on: kept and trimmed',
    );
    ok(lastUsed('award', false).reason === undefined, 'switched off again: the dialog opens empty');
    ok(lastUsed('ban', true).reason === undefined, 'each dialog keeps its own values');
    ok(startNumber(25, 1, 50, 1) === 25, 'a kept number inside the limits is used');
    ok(startNumber(80, 1, 50, 1) === 1 && startNumber(0, 1, 50, 1) === 1, 'outside the limits: the minimum');
    ok(startNumber(undefined, 5, 50, 5) === 5, 'nothing kept: the minimum');
    resetLastUsed();
}
