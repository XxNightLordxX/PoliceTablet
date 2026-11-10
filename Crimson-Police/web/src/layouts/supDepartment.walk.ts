// The Department screen of the Supervisor UI against the browser mocks (node walk.mjs, a gate step, MG3): its five
// tabs, each with the permission of the screen it replaces, the old keys sup_report, sup_controls and sup_review
// opening their tab (params kept), the tab a link or the landing picks, and the sidebar listing Department alone.

import '../mocks/core.mock';
import ui from '../../../locales/parts/ui.json';
import { request } from '../shared/nui';
import type { ScreenKey } from '../shared/navigation';
import type { Session } from '../shared/types';
import appSrc from '../App.tsx?raw';
import liveSrc from '../supervisor/screens/LiveMissions.tsx?raw';
import deptSrc from '../supervisor/screens/Department.tsx?raw';
import { navBadge } from './navBadges';
import { screensFor } from './screens';
import { DEPT_TABS, deptTabOf, deptTabsFor } from './supDepartment';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const locale = ui as Record<string, string>;
const as = (actions: string[], extra: Record<string, unknown> = {}) =>
    ({ actions, config: { ...extra } }) as unknown as Session;

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
    ok(res.ok && res.data, 'getSession answers');
    const session = res.data as Session;

    // the sidebar: Department in place of Department Report, Mission controls and Review Queue
    const keys = screensFor('supervisor', session).map(s => s.key);
    ok(keys.includes('sup_department'), 'the mock supervisor sees Department');
    for (const old of ['sup_report', 'sup_controls', 'sup_review']) {
        ok(!keys.includes(old as ScreenKey), `${old} is no sidebar entry any more`);
    }
    ok(line('ui.screen.sup_department'), 'Department has a title');
    for (const k of DEPT_TABS) ok(line(`sup.dept.tab.${k}`), `the ${k} tab has a label`);
    ok(deptTabsFor(session).join() === DEPT_TABS.join(), 'a full supervisor sees all five tabs, in order');

    // each tab keeps the permission of the screen it replaces
    ok(deptTabsFor(as(['fieldTraining'])).join() === 'training', 'a field training grant alone: Training only');
    ok(deptTabsFor(as(['reviewFlagged'])).join() === 'review', 'a review grant alone: Review only');
    ok(deptTabsFor(as(['handleDisputes'])).join() === 'review', 'a disputes grant alone: Review only');
    ok(deptTabsFor(as(['missionCalls'])).join() === 'calls', 'a mission calls grant alone: Calls & notices only');
    ok(
        deptTabsFor(as([], { missionControls: true })).join() === 'controls,calls',
        'a control outside the master switch: Controls (and the notices on Calls & notices)',
    );
    ok(deptTabsFor(as([])).length === 0, 'none of them: no tab');
    ok(deptTabsFor(null).length === 0, 'no session: no tab');
    ok(!screensFor('supervisor', as(['setTypePayout'])).some(s => s.key === 'sup_department'), 'no tab: no screen');

    // the old screen keys are gone: App navigates by the key as it is
    ok(!appSrc.includes('resolveSupervisorKey') && !appSrc.includes('resolveAdminKey'), 'App has no old-key redirects');

    // the tab shown: the asked one when allowed, else Review for the landing 'review', else the first allowed
    ok(deptTabOf({ deptTab: 'calls' }, session) === 'calls', 'an asked tab');
    ok(deptTabOf({}, session) === 'officers', 'nothing asked: Officers');
    ok(deptTabOf({ deptTab: 'bogus' }, session) === 'officers', 'an unknown tab: the first one');
    ok(
        deptTabOf({ deptTab: 'officers' }, as(['fieldTraining'])) === 'training',
        'a tab not allowed: the first allowed',
    );
    const landing = { ...session, config: { ...session.config, supervisorNav: { landing: 'review' } } } as Session;
    ok(deptTabOf({}, landing) === 'review', 'supervisorLanding review: the Review tab');
    ok(deptTabOf({ deptTab: 'controls' }, landing) === 'controls', 'a link still wins over the landing');

    // the Review Queue badge sits on Department; the mission calls panel moved off Live Missions
    const counts = { invites: 0, calls: 0, review: 3, commendations: 0, rewards: 0, onRun: false };
    ok(navBadge('sup_department', counts).badge === '3', 'the open review items show on Department');
    ok(!liveSrc.includes('<MissionCallsPanel'), 'Live Missions has no mission calls panel');
    ok(deptSrc.includes('<MissionCallsPanel') && deptSrc.includes('<DeptNoticesCard />'), 'Calls & notices has both');
    ok(deptSrc.includes('<FieldTrainingPanel showOff />'), 'Training says so while field training is off');
}

function line(k: string): boolean {
    return typeof locale[k] === 'string' && locale[k].length > 0;
}
