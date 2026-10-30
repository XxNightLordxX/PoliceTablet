// My options -> Dispatch and Opening the tablet (step O9) against the browser mocks (node walk.mjs, a gate step): the
// screen an open lands on (openOn), the remembered filters' list and a claim sent without the dialog.

import '../mocks/core.mock';
import '../mocks/missioncalls.mock';
import '../mocks/options.mock';
import type { OptionsView } from '../types/options';
import type { DispatchView } from '../types/missioncalls';
import { filterOf, withFilter } from './filters';
import { action, clientAction, request } from './nui';
import { openScreenFor } from './openOn';
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
    const res = await request<Session>('getSession', { ui: 'officer' });
    ok(res.ok && res.data, 'getSession answers');
    const base = res.data as Session;
    const with_ = (openOn: string | undefined, onRun: boolean, readyCheck: boolean): Session => ({
        ...base,
        options: openOn ? { openOn } : {},
        opening: { onRun, readyCheck },
    });

    // openOn
    ok(openScreenFor('officer', with_(undefined, true, false)) === null, 'no option: the last screen, as before');
    ok(openScreenFor('officer', with_('last', true, true)) === null, "'last': the last screen, even on a run");
    ok(openScreenFor('officer', with_('home', true, false)) === 'home', "'home': Home");
    ok(openScreenFor('officer', with_('active_on_run', true, false)) === 'active', 'on a run: Active Mission');
    ok(openScreenFor('officer', with_('active_on_run', false, true)) === 'unit', 'a ready check waits: Unit');
    ok(openScreenFor('officer', with_('active_on_run', false, false)) === null, 'no run: the last screen');
    ok(openScreenFor('supervisor', with_('home', true, false)) === null, 'the Supervisor UI keeps its screen');

    // the remembered filters: one entry per part
    let list = withFilter([], 'dispatch.filter', 'near');
    list = withFilter(list, 'leaderboard.period', 'monthly');
    list = withFilter(list, 'dispatch.filter', 'claimable');
    ok(list.length === 2, 'one entry per filter');
    ok(filterOf(list, 'dispatch.filter') === 'claimable', 'the last choice is kept');
    ok(filterOf(list, 'leaderboard.period') === 'monthly', 'another screen keeps its own');
    ok(filterOf(list, 'leaderboard.metric') === null && filterOf(null, 'dispatch.filter') === null, 'none: null');

    // the options: the new rows, and the filters list is not a row
    const opts = await request<OptionsView>('getOptions', {});
    const schema = Object.values(opts.data?.schema ?? []);
    for (const key of ['skipClaimConfirm', 'callAlerts', 'dispatchKeyAfterCall', 'openOn', 'rememberFilters']) {
        ok(
            schema.some(d => d.key === key),
            `${key} is a row of My options`,
        );
    }
    ok(!schema.some(d => d.key === 'filters'), 'the remembered filters are not a row');
    const saved = await clientAction<{ options?: Record<string, unknown> }>('setLocalOption', {
        key: 'filters',
        value: list,
    });
    ok(saved.ok && filterOf(saved.data?.options?.filters, 'dispatch.filter') === 'claimable', 'the filters are kept');

    // one click: the claim goes out with the call id alone and the ready check starts
    const view = await request<DispatchView>('getMissionCalls', {});
    const call = Object.values(view.data?.calls ?? []).find(c => c.status === 'ready');
    ok(call, 'the mock has a ready call');
    if (call) {
        const claim = await action<{ pending?: boolean }>('server:claimMissionCall', { callId: call.id });
        ok(claim.ok && claim.data?.pending === true, 'a one-click claim is a plain claim: the ready check starts');
    }
}
