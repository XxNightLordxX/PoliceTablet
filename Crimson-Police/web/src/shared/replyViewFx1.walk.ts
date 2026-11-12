// Replies that carry the fresh view, against the browser mocks (node walk.mjs, a gate step): the supervisor and admin
// actions whose replies carry the screen's fresh view (Mission calls, Live Missions, Clear cooldown, the activity
// dialog, Reset all, Admin System -> Storage), so the screen needs no second request.

// Against the browser mocks (node walk.mjs, a gate step): Admin System -> Storage, the supervisor's Mission calls
// (post, withdraw), Live Missions ("+ minutes"), Clear cooldown, Give points, Commend and Revoke from the activity
// dialog (with activityOf only) and Settings -> Reset all each answer with their screen's fresh view.

import '../mocks/admin_system.mock';
import '../mocks/missioncalls.mock';
import '../mocks/oversight.mock';
import '../mocks/boards.mock';
import '../mocks/settings.mock';
import type { StorageView } from '../types/admin_system';
import type { OfficerActivity, OfficerCooldowns } from '../types/boards';
import type { SupCallsView } from '../types/missioncalls';
import type { LiveRunsData } from '../types/oversight';
import type { SettingsData } from '../types/settings';
import { action, request } from './nui';
import { replyView } from './replyView';

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
    // Admin UI -> System -> Storage: each action answers with the Storage view
    for (const [name, payload] of [
        ['server:admin:storageCopy', { direction: 'toFiles', force: false, confirm: 'COPY' }],
        ['server:admin:setStorageMode', { enabled: true, folder: 'saves', reason: 'move', confirm: 'SWITCH' }],
        ['server:admin:useStoreAgain', { reason: 'back', confirm: 'USE' }],
    ] as const) {
        const res = await action(name, payload);
        const v = replyView<StorageView>(res.data, 'view');
        ok(res.ok && !!v && Array.isArray(v.tables), `${name} answers with the Storage view`);
    }

    // Supervisor -> Mission calls: post a call and withdraw it, each reply the panel's view
    const made = await action('server:sup:mcPost', { type: 'patrol', area: null });
    const id = made.ok && made.data ? (made.data as { id?: number }).id : undefined;
    const after = replyView<SupCallsView>(made.data, 'view');
    ok(made.ok && !!after && after.open.some(c => c.id === id), 'Post a call answers with the panel, the call in it');
    const gone = await action('server:sup:mcWithdraw', { callId: id, reason: 'Posted by mistake' });
    const left = replyView<SupCallsView>(gone.data, 'view');
    ok(gone.ok && !!left && !left.open.some(c => c.id === id), 'Withdraw answers with the panel without it');

    // Supervisor -> Live Missions: "+ minutes" answers with the view, the time added on the run
    const live = await request<LiveRunsData>('sup:getLiveRuns', {});
    const going = live.ok && live.data ? live.data.runs.find(r => r.state === 'in_progress') : undefined;
    ok(!!going, 'the mock lists a running mission');
    if (going) {
        const res = await action('server:sup:addRunTime', { runId: going.runId, minutes: 2, reason: 'Long drive' });
        const v = replyView<LiveRunsData>(res.data, 'view');
        const run = v ? v.runs.find(r => r.runId === going.runId) : undefined;
        ok(res.ok && !!run && (run.timeAdded ?? 0) >= 120, '+ minutes answers with the view, the minutes on the run');
    }

    // the activity dialog: an action sent with activityOf answers with the officer's activity, without it none
    const report = await request<{ officers?: { citizenid: string }[] }>('sup:getDeptReport', {});
    const officer = report.ok && report.data ? (report.data.officers ?? [])[1] : undefined;
    ok(!!officer, 'the mock report lists an officer');
    if (officer) {
        // Clear cooldown: the reply carries the dialog's list without the cleared cooldown
        const clear = { citizenid: officer.citizenid, scope: 'type', key: 'patrol', reason: 'Wrong call' };
        const cd = await action('server:sup:clearCooldowns', clear);
        const list = replyView<OfficerCooldowns>(cd.data, 'view');
        ok(cd.ok && !!list && !list.cooldowns.types.some(t => t.key === 'patrol'), 'Clear answers with the fresh list');
        const award = { citizenid: officer.citizenid, points: 5, reason: 'Great stop' };
        const plain = await action('server:sup:awardPoints', award);
        ok(plain.ok && !replyView(plain.data, 'activity'), 'from another screen: no activity in the reply');
        const res = await action('server:sup:awardPoints', { ...award, activityOf: officer.citizenid });
        const a = replyView<OfficerActivity>(res.data, 'activity');
        ok(res.ok && !!a && a.officer?.citizenid === officer.citizenid, 'from the dialog: his fresh activity');

        // Commend from the dialog: his fresh activity with the new commendation; Revoke: the activity without it
        const commend = { citizenid: officer.citizenid, kind: 'teamwork', citation: 'Held the line at the bank job.' };
        const plainC = await action('server:sup:commend', commend);
        ok(plainC.ok && !replyView(plainC.data, 'activity'), 'Commend from another screen: no activity in the reply');
        const given = await action('server:sup:commend', { ...commend, activityOf: officer.citizenid });
        const cid = given.ok && given.data ? (given.data as { id?: number }).id : undefined;
        const ga = replyView<OfficerActivity>(given.data, 'activity');
        ok(given.ok && !!ga && (ga.commendations ?? []).some(c => c.id === cid), 'Commend: the activity lists it');
        const rv = await action('server:sup:revokeCommendation', {
            id: cid,
            reason: 'Wrong officer',
            activityOf: officer.citizenid,
        });
        const ra = replyView<OfficerActivity>(rv.data, 'activity');
        ok(rv.ok && !!ra && !(ra.commendations ?? []).some(c => c.id === cid), 'Revoke: the activity without it');
    }

    // Admin UI -> Settings -> Reset all: the reply carries the whole Settings view
    const reset = await action('server:admin:resetAllSettings', {});
    const sv = replyView<SettingsData>(reset.data, 'view');
    ok(reset.ok && !!sv && Array.isArray(sv.sections), 'Reset all answers with the Settings view');
}
