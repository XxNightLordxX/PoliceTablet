// Admin UI · System → Jobs walked against the browser mocks (node walk.mjs, a gate step): one list of every timed
// job with when it runs, its settings and its last result; Run now runs a job that allows it (with a reason) and is
// refused for a week reset or a job switched off; the global search jumps to the tab.

import '../../mocks/admin_system.mock';
import { ADMIN_JUMPS } from '../../layouts/adminNav';
import { action, request } from '../../shared/nui';
import type { JobsView } from '../../types/admin_system';

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
        ADMIN_JUMPS.some(
            j => j.screen === 'admin_system' && j.params.tab === 'jobs' && j.label === 'sysadmin.ui.tab.jobs',
        ),
        'the search jumps to System → Jobs',
    );
    ok(!ADMIN_JUMPS.some(j => j.params.tab === 'cleanup'), 'the old Clean-up tab is gone');
    const res = await request<JobsView>('admin:getJobs', {});
    const jobs = res.data?.jobs ?? [];
    const kinds = new Set(jobs.map(j => j.when));
    ok(kinds.has('daily') && kinds.has('weekly') && kinds.has('every'), 'daily, weekly and timer jobs in one list');
    const cleanup = jobs.find(j => j.id === 'cleanup');
    ok(cleanup && cleanup.settings.some(s => s.path === 'Retention.auditDays'), 'a job lists its own settings');
    ok(cleanup && cleanup.last && cleanup.last.result, 'and its last result');
    ok(
        (await refused(action('server:admin:runJobNow', { id: 'board_week', reason: 'r' }))) === 'err.job_not_manual',
        'a week reset only runs at its own time',
    );
    ok(
        (await refused(action('server:admin:runJobNow', { id: 'backup', reason: 'r' }))) === 'err.job_off',
        'a job switched off is not run',
    );
    ok(
        (await refused(action('server:admin:runJobNow', { id: 'cleanup' }))) === 'err.reason_required',
        'Run now needs a reason',
    );
    const run = await action<JobsView>('server:admin:runJobNow', { id: 'cleanup', reason: 'Test' });
    const after = run.data?.jobs.find(j => j.id === 'cleanup');
    ok(run.ok && after?.last?.by === 'ADM00001', 'Run now runs it and the list says who ran it');
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
