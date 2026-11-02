// The criminal tablet (step G2) against the browser mocks (node walk.mjs, a gate step): the view normalised, the
// landing screen and badges, joining, a job accepted into Active, giving up, and the refusals as error keys.

import '../mocks/criminal.mock';
import { mockCrimJob, mockCrimReset } from '../mocks/criminal.mock';
import { action, request } from '../shared/nui';
import type { CrimView } from '../types/criminal';
import { badgeOf, hoursLeft, landingOf, minutesLeft, normalizeCrimView, outcomeKey, rolesPayload } from './model';

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

async function get(): Promise<CrimView | null> {
    const res = await request<CrimView>('crimtab:get', {});
    return res.ok ? normalizeCrimView(res.data) : null;
}

async function act(payload: Record<string, unknown>): Promise<{ view: CrimView | null; error?: string }> {
    const res = await action<CrimView>('server:crimtab:act', payload);
    return res.ok ? { view: normalizeCrimView(res.data) } : { view: null, error: res.error };
}

async function steps(): Promise<void> {
    mockCrimReset();
    // normalising: empty Lua tables come as {}, missing numbers get their defaults
    const raw = normalizeCrimView({ status: { roles: {}, allRoles: {} }, jobs: {}, history: {}, strikes: {} });
    ok(raw && raw.jobs.length === 0 && raw.history.length === 0, 'an empty Lua table is an empty list');
    ok(raw && raw.status.allRoles.length === 3, 'no roles from the server: the three suspects');
    ok(raw && raw.rules.windowMinutes === 60 && raw.rules.strikes === 3, 'missing rules: the shipped defaults');
    ok(normalizeCrimView(null) === null, 'no view: null');

    let view = await get();
    ok(view && !view.status.listed && view.status.canJoin, 'Home: not volunteering, may join');
    ok(landingOf(view, null) === 'home', 'nothing going on: lands on Home');
    ok(landingOf(view, 'rules') === 'rules', 'Lua names a screen: that one');
    ok(landingOf(view, 'nope') === 'home', 'an unknown screen: Home');
    ok(badgeOf(view, 'history') === '1', 'History shows the strike that still counts');

    let r = await act({ what: 'join', roles: rolesPayload({ runner: true, driver: false }) });
    ok(r.view?.status.listed && r.view.status.roles.join() === 'runner', 'join: listed for the picked suspect');
    ok(minutesLeft(r.view?.status.untilAt, r.view?.now ?? 0) === 60, 'an hour window');
    r = await act({ what: 'join', roles: ['runner'] });
    ok(!r.view && !!r.error, 'a second join: refused (the server answers its volunteer.refused text)');
    r = await act({ what: 'roles', roles: [] });
    ok(!r.view && !!r.error, 'no suspect picked: refused');

    mockCrimJob();
    view = await get();
    ok(
        view && view.jobs.length === 1 && view.jobs[0].area === 'Grove Street, Davis',
        'Jobs: the question with its area',
    );
    ok(landingOf(view, null) === 'jobs' && badgeOf(view, 'jobs') === '1', 'a question waits: Jobs, with a badge');
    ok(view?.jobs[0].reward?.startsWith('$1,500') === true, 'the job shows what Pay volunteer suspects pays (G7)');
    const token = view?.jobs[0].token;
    r = await act({ what: 'answer', token: 'stale', yes: true });
    ok(r.error === 'err.crimtab_job_gone', 'a stale token: the job is gone');
    r = await act({ what: 'answer', token, yes: true });
    ok(r.view?.active?.phase === 'travel' && r.view.jobs.length === 0, 'Accept: Active, travelling to the meet point');
    ok(landingOf(r.view, null) === 'active' && badgeOf(r.view, 'active') === '!', 'playing: lands on Active');
    r = await act({ what: 'cancel' });
    ok(r.view && !r.view.active, 'give up: no case any more');
    r = await act({ what: 'cancel' });
    ok(!r.view && !!r.error, 'nothing to give up: refused');
    r = await act({ what: 'stop' });
    ok(r.view && !r.view.status.listed, 'stop: off the list');
    r = await act({ what: 'hack' });
    ok(r.error === 'err.invalid_payload', 'an unknown action: refused');

    // History texts
    ok(
        outcomeKey({ endedAt: 0, outcome: 'void', dropout: 'no_show' }) === 'crimtab.outcome.dropout_no_show',
        'a dropout',
    );
    ok(outcomeKey({ endedAt: 0, outcome: 'booked' }) === 'crimtab.outcome.booked', 'an outcome');
    ok(outcomeKey({ endedAt: 0, outcome: 'weird' }) === 'crimtab.outcome.got_away', 'an unknown one: got away');
    ok(hoursLeft(1000 + 3601, 1000) === 2 && hoursLeft(500, 1000) === 0, 'hours left round up, past is 0');
}
