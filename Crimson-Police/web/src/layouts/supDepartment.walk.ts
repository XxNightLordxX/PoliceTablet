// The Department screen of the Supervisor UI against the browser mocks (node walk.mjs, a gate step, MG3): its five
// tabs, each with the permission of the screen it replaces, the old keys sup_report, sup_controls and sup_review
// opening their tab (params kept), the tab a link or the landing picks, and the sidebar listing Department alone.

// The Department screen of the Supervisor UI against the browser mocks (node walk.mjs, a gate step, MG3): its five
// tabs, each with the permission of the screen it replaces, the old keys sup_report, sup_controls and sup_review
// opening their tab (params kept), the tab a link or the landing picks, and the sidebar listing Department alone.
// UI4: today at a glance above the tabs (todayTiles against the sup:getToday mock) and the officer's side panel
// (officerActions, ftoRoleOf; one panel with the forms in it, no dialog per action).

import '../mocks/core.mock';
import ui from '../../../locales/parts/ui.json';
import { request } from '../shared/nui';
import type { ScreenKey } from '../shared/navigation';
import type { Session } from '../shared/types';
import appSrc from '../App.tsx?raw';
import liveSrc from '../supervisor/screens/LiveMissions.tsx?raw';
import deptSrc from '../supervisor/screens/Department.tsx?raw';
import reportSrc from '../supervisor/screens/DeptReport.tsx?raw';
import mcLocale from '../../../locales/parts/mission_controls.json';
import { ftoRoleOf, officerActions } from '../supervisor/components/officerPanel';
import type { OfficerActivity } from '../types/boards';
import type { FtoDept } from '../types/fieldTraining';
import type { SupToday } from '../types/oversight';
import { navBadge } from './navBadges';
import { screensFor } from './screens';
import { DEPT_TABS, deptTabOf, deptTabsFor, todayTiles } from './supDepartment';

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
    ok(deptTabsFor(session).join() === DEPT_TABS.join(), 'a full supervisor sees all six tabs, in order');
    ok(
        !deptTabsFor({ ...session, config: { ...session.config, restrictionsTab: false } }).includes('restrictions'),
        'restrictionsTab = false: no Restrictions tab',
    );
    ok(
        deptTabsFor(as(['viewMissionList'], { restrictionsTab: true })).includes('restrictions'),
        "FIN4: every supervisor sees his department's restrictions",
    );

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
    ok(
        deptSrc.includes('<MissionCallsPanel') && deptSrc.includes('<NoticesCard kind="department" />'),
        'Calls & notices has both',
    );
    ok(deptSrc.includes('<FieldTrainingPanel showOff />'), 'Training says so while field training is off');

    await today(session, keys);
    await panel();
}

// Today at a glance (UI4): on duty, runs going, waiting for review and the controls used today, each opening its tab.
async function today(session: Session, keys: ScreenKey[]): Promise<void> {
    const res = await request<SupToday>('sup:getToday', {});
    ok(res.ok && res.data, 'sup:getToday answers');
    const data = res.data as SupToday;
    const tabs = deptTabsFor(session);
    const tiles = todayTiles(data, 3, tabs, keys);
    ok(tiles.map(x => x.key).join() === 'onDuty,running,review,controls', 'a full supervisor sees all four tiles');
    for (const x of tiles) ok(line(`sup.today.${x.key}`), `the ${x.key} tile has a label`);
    ok(line('sup.today.title'), 'today at a glance has a title');
    const by = Object.fromEntries(tiles.map(x => [x.key, x]));
    ok(by.onDuty.value === '6' && by.onDuty.open?.deptTab === 'officers', 'on duty: the count, opens Officers');
    ok(
        by.running.value === '2' && by.running.open?.screen === 'sup_live',
        'runs going: the count, opens Live Missions',
    );
    ok(
        by.review.value === '3' && by.review.warn && by.review.open?.deptTab === 'review',
        'waiting: amber, opens Review',
    );
    ok(by.controls.value === '43 / 103' && !by.controls.warn, 'controls: used of the day counts, not all spent');
    ok(by.controls.open?.deptTab === 'controls', 'controls: opens Controls');
    const spent = todayTiles({ ...data, controls: { counted: 1, used: 3, perDay: 3 } }, 0, tabs, keys);
    ok(spent.find(x => x.key === 'controls')?.warn === true, 'every use of today spent: amber');
    ok(spent.find(x => x.key === 'review')?.warn === false, 'nothing waiting: not amber');
    ok(todayTiles(null, 0, tabs, keys)[0].value === '–', 'before the answer: a dash');
    const noCount = todayTiles({ ...data, controls: { counted: 0, used: 0, perDay: 0 } }, 0, tabs, keys);
    ok(!noCount.some(x => x.key === 'controls'), 'no control with a day count: no controls tile');
    ok(todayTiles(data, 0, ['review'], keys).length === 0, 'without the Officers tab: no tiles (as sup:getToday)');
    const noReview = todayTiles(data, 2, ['officers'], []);
    ok(!noReview.some(x => x.key === 'review'), 'without the Review tab: no waiting tile');
    ok(noReview.find(x => x.key === 'running')?.open === null, 'without Live Missions: runs going opens nothing');
    ok(noReview.find(x => x.key === 'controls')?.open === null, 'without Controls: the controls tile opens nothing');
    ok(deptSrc.includes('<Today tabs={tabs}'), 'Department shows it above the tabs');
}

// The officer's side panel (UI4): every action on the same terms as before, each form in the one panel.
async function panel(): Promise<void> {
    const act = (extra: Partial<OfficerActivity>) => ({ officer: { citizenid: 'A' }, ...extra }) as OfficerActivity;
    const ctl = { min: 1, max: 5 };
    const full = officerActions({
        activity: act({
            awardPoints: ctl as never,
            missionBan: { ...ctl, canLift: true } as never,
            cooldownClear: {},
        }),
        canCommend: true,
        self: false,
        fto: { kind: 'candidate' },
    });
    ok(full.join() === 'points,ban,cooldown,commend,fto', 'every action, in order');
    ok(officerActions({ activity: null, canCommend: true, self: true, fto: null }).length === 0, 'never on himself');
    const banned = officerActions({
        activity: act({
            missionBan: { ...ctl, canLift: false } as never,
            missionBanState: { until: 1, by: 'X' } as never,
        }),
        canCommend: false,
        self: false,
        fto: null,
    });
    ok(banned.length === 0, 'a ban someone else set: no Lift (as before), no Commend without issueCommendation');
    const fto = {
        pairs: [
            { rookie: { citizenid: 'R1', name: 'R1' }, trainer: { citizenid: 'T1', name: 'T1' }, signed: 0, total: 2 },
        ],
        candidates: [
            { citizenid: 'T1', name: 'T1' },
            { citizenid: 'C1', name: 'C1' },
        ],
        trainers: [{ citizenid: 'T1', name: 'T1' }],
    } as unknown as FtoDept;
    ok(ftoRoleOf(fto, 'R1')?.kind === 'rookie', 'a rookie in training: his training (End training)');
    const tr = ftoRoleOf(fto, 'T1');
    ok(tr?.kind === 'trainer' && tr.rookies.length === 1, 'a trainer: his rookies, give him one');
    ok(ftoRoleOf(fto, 'C1')?.kind === 'candidate', 'an officer not in training: pair him with a trainer');
    const doneFto = {
        ...fto,
        pairs: [{ ...fto.pairs[0], doneAt: 5 }],
        candidates: [...fto.candidates, { citizenid: 'R1', name: 'R1' }],
    } as unknown as FtoDept;
    const again = ftoRoleOf(doneFto, 'R1');
    ok(again?.kind === 'candidate' && again.done?.doneAt === 5, 'a rookie whose training is done: pair him again here');
    ok(reportSrc.includes('todayChanged()'), 'a panel action refreshes today at a glance');
    ok(deptSrc.includes('TabbedScreen') && !deptSrc.includes('<Tabs'), 'Department is a TabbedScreen');
    ok(ftoRoleOf(fto, 'X') === null && ftoRoleOf(false, 'C1') === null, 'unknown, or field training off: nothing');
    ok(reportSrc.includes('placement="right"') && reportSrc.includes('<OfficerPanel'), 'one side panel per officer');
    ok(!/<(AwardPoints|MissionBan|ClearCooldown|Commend)Dialog\b/.test(reportSrc), 'no dialog per action any more');
    for (const k of ['sup.panel.actions', 'sup.panel.no_actions', 'sup.panel.runs', 'sup.panel.no_rookies']) {
        ok(line(k), `${k} has a line`);
    }
    const mc = mcLocale as Record<string, string>;
    ok(!('sup.award.title' in mc) && !('sup.cd.title' in mc), 'the old dialog titles are gone');
}

function line(k: string): boolean {
    return typeof locale[k] === 'string' && locale[k].length > 0;
}
