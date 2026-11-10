// Supervisor UI sidebar and landing against the browser mocks (node walk.mjs, a gate step): Config.Tablet's
// supervisorByTask, supervisorCompact and supervisorLanding reach the Supervisor UI as the session's
// config.supervisorNav, and the layout changes only when they are set.

import '../mocks/core.mock';
import { request } from '../shared/nui';
import type { ScreenKey } from '../shared/navigation';
import type { Session } from '../shared/types';
import { currentScreen } from './screens';
import { inSections } from './Sidebar';
import {
    CLASSIC_SUP_NAV,
    SUPERVISOR_TASKS,
    SUPERVISOR_TASK_OF,
    supervisorLanding,
    supervisorNavOf,
    supervisorTaskOf,
} from './supervisorNav';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

// the Supervisor screens in registry order (layouts/screens.ts SUPERVISOR_SCREENS)
const REGISTRY = [
    'sup_missions',
    'sup_crossdept',
    'sup_live',
    'sup_department',
    'sup_payouts',
    'sup_builder',
] as ScreenKey[];
// a supervisor who may see the Officers and Review tabs of Department
const sessionWith = (n: unknown) =>
    ({ config: { supervisorNav: n }, actions: ['viewMissionList', 'reviewFlagged'] }) as unknown as Session;

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

async function steps(): Promise<void> {
    const res = await request<Session>('getSession', { ui: 'supervisor' });
    ok(res.ok, 'getSession answers');
    const nav = supervisorNavOf(res.data);
    ok(!nav.byTask && !nav.compact && nav.landing === 'first', 'the mock session ships the Supervisor UI as before');
    ok(supervisorNavOf(null) === CLASSIC_SUP_NAV, 'no session: as before');
    ok(supervisorNavOf(sessionWith({ landing: 'payouts' })).landing === 'first', 'an unknown landing counts as first');

    // every Supervisor screen has a task, and every task is one of the three headings
    ok(
        REGISTRY.every(k => SUPERVISOR_TASKS.includes(SUPERVISOR_TASK_OF[k])),
        'every screen sits under a task',
    );

    // one list (shipped): no task, no headings, the registry order
    const flat = REGISTRY.map(k => ({ key: k, play: supervisorTaskOf(k, CLASSIC_SUP_NAV) }));
    ok(
        flat.every(i => i.play === undefined),
        'supervisorByTask off: no screen has a task',
    );
    const asIs = inSections(flat, undefined);
    ok(asIs.map(x => x.item.key).join(',') === REGISTRY.join(','), 'supervisorByTask off: the registry order');
    ok(
        asIs.every(x => !x.heading),
        'supervisorByTask off: no headings',
    );

    // grouped by task: People, Missions, Rewards, each heading once over its first screen (MG3: Review is a tab of
    // Department, under People)
    const byTask = { ...CLASSIC_SUP_NAV, byTask: true };
    const sections = SUPERVISOR_TASKS.map(k => ({ key: k, label: k }));
    const grouped = inSections(
        REGISTRY.map(k => ({ key: k, play: supervisorTaskOf(k, byTask) })),
        sections,
    );
    ok(
        grouped.map(x => x.item.key).join(',') ===
            'sup_department,sup_missions,sup_crossdept,sup_live,sup_builder,sup_payouts',
        'byTask: People, then Missions in their order, then Rewards',
    );
    ok(
        grouped
            .filter(x => x.heading)
            .map(x => x.heading)
            .join(',') === 'people,missions,rewards',
        'byTask: each heading once',
    );
    // a supervisor without the Payouts screen: no empty Rewards heading
    const some = inSections(
        REGISTRY.filter(k => k !== 'sup_payouts').map(k => ({ key: k, play: supervisorTaskOf(k, byTask) })),
        sections,
    );
    ok(!some.some(x => x.heading === 'rewards'), 'a hidden screen leaves no empty heading');

    // landing: 'first' = the first one shown; a set landing when shown; otherwise the first one
    ok(supervisorLanding(CLASSIC_SUP_NAV, REGISTRY) === 'sup_missions', 'first: the first screen (as before)');
    const review = { ...CLASSIC_SUP_NAV, landing: 'review' as const };
    ok(supervisorLanding(review, REGISTRY) === 'sup_department', 'review: Department');
    ok(supervisorLanding(review, REGISTRY, ['officers', 'review']) === 'sup_department', 'review: with its tab');
    ok(supervisorLanding(review, REGISTRY, ['officers']) === 'sup_missions', 'review without its tab: the first one');
    ok(
        supervisorLanding({ ...CLASSIC_SUP_NAV, landing: 'report' }, REGISTRY, ['officers']) === 'sup_department',
        'report: Department',
    );
    ok(supervisorLanding({ ...CLASSIC_SUP_NAV, landing: 'live' }, REGISTRY) === 'sup_live', 'live: Live Missions');
    ok(
        supervisorLanding({ ...CLASSIC_SUP_NAV, landing: 'live' }, ['sup_payouts'] as ScreenKey[]) === 'sup_payouts',
        'a landing the supervisor may not see: the first screen',
    );
    ok(supervisorLanding(CLASSIC_SUP_NAV, []) === undefined, 'no screens: none');

    // the screen shown: the landing until a screen is picked, then the picked one; the other UIs as before
    const reviewS = sessionWith({ byTask: false, compact: false, landing: 'review' });
    const first = sessionWith({ byTask: false, compact: false, landing: 'first' });
    const start = { key: 'sup_missions' as ScreenKey };
    ok(currentScreen('supervisor', first, REGISTRY, start) === 'sup_missions', 'first, nothing picked: as before');
    ok(
        currentScreen('supervisor', reviewS, REGISTRY, start) === 'sup_department',
        'review, nothing picked: Department',
    );
    ok(
        currentScreen('supervisor', reviewS, REGISTRY, { key: 'sup_payouts', picked: true }) === 'sup_payouts',
        'a picked screen stays',
    );
    ok(
        currentScreen('supervisor', first, ['sup_department'] as ScreenKey[], start) === 'sup_department',
        'the start screen not shown: the first one shown (as before)',
    );
    ok(
        currentScreen('officer', reviewS, ['home', 'board'] as ScreenKey[], { key: 'board' }) === 'board',
        'the Officer UI keeps its screen as before',
    );
}
