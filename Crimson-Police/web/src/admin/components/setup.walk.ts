// Admin UI -> Home's First-start setup against the browser mocks (node walk.mjs, a gate step): Home says to show it,
// the answers start as the server runs now (a finish with nothing changed sends nothing but the done mark), each
// change goes into the one server:admin:finishSetup payload, and finishing (or skipping) takes it off Home.

import '../../mocks/admin_system.mock';
import { action, request } from '../../shared/nui';
import type { AdminHomeData, SetupReply, SetupView } from '../../types/admin_system';
import {
    SETUP_STEPS,
    changeCount,
    finishPayload,
    gradeChoices,
    initialAnswers,
    scriptLine,
    toggledNew,
    unclaimedJobs,
} from './setup';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    const loc = (globalThis as unknown as { window: { location: { search: string } } }).window.location;
    const before = loc.search;
    loc.search = '?ui=admin&setup';
    try {
        const home = await request<AdminHomeData>('admin:getHome', {});
        ok(home.ok && home.data?.setup === true, 'Home says the setup shows');
        const res = await request<SetupView>('admin:getSetup', {});
        ok(res.ok && res.data, 'admin:getSetup answers');
        const view = res.data as SetupView;
        ok(SETUP_STEPS.join(',') === 'departments,desks,storage,scripts,preset', 'five steps in order');

        // the answers start as the server runs now: nothing to send
        const start = initialAnswers(view);
        ok(JSON.stringify(finishPayload(view, start)) === '{}', 'untouched answers send nothing');
        ok(changeCount(view, start) === 0, 'nothing would change');

        // the Qbox police jobs no department lists, and the grades of a department's jobs
        ok(
            unclaimedJobs(view)
                .map(j => j.name)
                .join(',') === 'bcso,sasp',
            'bcso and sasp have no department yet',
        );
        const grades = gradeChoices(view, ['police', 'bcso']);
        ok(grades.length === 5 && grades[0]?.level === 0 && grades[4]?.name === 'Chief', 'grades once, lowest first');
        ok(gradeChoices(view, []).length === 0, 'no job: no grades');

        // every kind of answer
        const a = initialAnswers(view);
        a.departments.police = { jobs: ['police', 'sasp'], supervisorGrade: 4, enabled: true };
        a.add = toggledNew(toggledNew([], 'bcso', true), 'sasp', true);
        a.add = a.add.map(n =>
            n.job === 'bcso' ? { ...n, themeFrom: 'police', logoUrl: ' https://x.test/b.png ' } : n,
        );
        a.add = toggledNew(a.add, 'sasp', false);
        a.desks = [1, 3];
        a.integrations.banking = 'none';
        a.preset = 'serious';
        const p = finishPayload(view, a) as {
            departments?: Record<string, { jobs: string[]; supervisorGrade: number }>;
            add?: { job: string; themeFrom?: string; logoUrl?: string }[];
            desks?: number[];
            integrations?: Record<string, string>;
            preset?: string;
        };
        ok(p.departments?.police?.jobs.join(',') === 'police,sasp', 'the department jobs');
        ok(p.departments?.police?.supervisorGrade === 4, 'the supervisor grade');
        ok(
            JSON.stringify(p.add) === '[{"job":"bcso","themeFrom":"police","logoUrl":"https://x.test/b.png"}]',
            'a new department for bcso, with the colours of police and its logo link (sasp unticked again)',
        );
        const plain = initialAnswers(view);
        plain.add = toggledNew(plain.add, 'sasp', true);
        ok(
            JSON.stringify(finishPayload(view, plain).add) === '[{"job":"sasp"}]',
            'no colours or logo picked: the job only',
        );
        ok(p.desks?.join(',') === '1,3', 'the desks kept');
        ok(JSON.stringify(p.integrations) === '{"banking":"none"}', 'only the script changed');
        ok(p.preset === 'serious', 'the preset');
        ok(changeCount(view, a) === 5, 'five things change');

        // a department left with no job is not sent (the server needs one)
        const empty = initialAnswers(view);
        empty.departments.police = { jobs: [], supervisorGrade: 3, enabled: true };
        ok(finishPayload(view, empty).departments === undefined, 'no job: the department is left as it is');

        // what each script line says
        ok(scriptLine({ setting: 'auto', active: 'ps-dispatch' }).key === 'admin.setup.script_active', 'serving');
        ok(scriptLine({ setting: 'none', why: 'off' }).key === 'admin.setup.script_off', 'turned off');
        ok(scriptLine({ setting: 'auto', why: 'missing' }).key === 'admin.setup.script_missing', 'none found');

        // finishing takes it off Home
        const done = await action<SetupReply>('server:admin:finishSetup', p);
        ok(done.ok && done.data?.preset?.key === 'serious', 'finish applies the preset');
        const after = await request<AdminHomeData>('admin:getHome', {});
        ok(after.ok && after.data?.setup === false, 'Home no longer shows it');
    } finally {
        loc.search = before;
    }
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
