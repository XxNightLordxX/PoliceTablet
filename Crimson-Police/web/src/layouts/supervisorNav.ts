// The Supervisor UI sidebar and landing: Config.Tablet.supervisorByTask (the screens grouped by task under
// People, Missions and Rewards), supervisorCompact (icons only) and supervisorLanding (the screen it opens on).
// Only the layout changes: the same screens show, a hidden one stays hidden, keys and links stay the same.

// The Supervisor UI sidebar and landing: supervisorNavOf reads the session's config.supervisorNav
// (Config.Tablet.supervisorByTask, supervisorCompact, supervisorLanding; anything unknown = as before),
// supervisorTaskOf gives a screen its task heading (People, Missions, Rewards) while grouped, and
// supervisorLanding picks the screen it opens on (the first one when the landing is not shown). MG3: the Department
// screen took in the Department Report, Mission controls and the Review Queue, so the landings 'report' and 'review'
// open Department on its Officers or Review tab (layouts/supDepartment.ts deptTabOf) and Review has no heading.
// Walk: supervisorNav.walk.ts.

import type { ScreenKey } from '../shared/navigation';
import type { Session } from '../shared/types';
import type { DeptTab } from './supDepartment';

export type SupervisorLanding = 'first' | 'report' | 'review' | 'live';
export type SupervisorNav = { byTask: boolean; compact: boolean; landing: SupervisorLanding };
export type SupervisorTask = 'people' | 'missions' | 'rewards';

export const CLASSIC_SUP_NAV: SupervisorNav = { byTask: false, compact: false, landing: 'first' };

// The task headings in order (titles: ui.nav.task.<key>).
export const SUPERVISOR_TASKS: SupervisorTask[] = ['people', 'missions', 'rewards'];

// The task each Supervisor screen is listed under when the sidebar is grouped by task.
export const SUPERVISOR_TASK_OF: Record<string, SupervisorTask> = {
    sup_department: 'people',
    sup_missions: 'missions',
    sup_live: 'missions',
    sup_crossdept: 'missions',
    sup_builder: 'missions',
    sup_payouts: 'rewards',
};

const LANDING_SCREEN: Record<Exclude<SupervisorLanding, 'first'>, ScreenKey> = {
    report: 'sup_department',
    review: 'sup_department',
    live: 'sup_live',
};
// the Department tab a landing needs (a supervisor without it opens on the first screen, as before)
const LANDING_TAB: Partial<Record<SupervisorLanding, DeptTab>> = { report: 'officers', review: 'review' };

// The session's Supervisor UI settings; an older session or an unknown value = as before.
export function supervisorNavOf(session: Session | null | undefined): SupervisorNav {
    const n = session?.config?.supervisorNav;
    if (!n || typeof n !== 'object') return CLASSIC_SUP_NAV;
    const landing: SupervisorLanding =
        n.landing === 'report' || n.landing === 'review' || n.landing === 'live' ? n.landing : 'first';
    return { byTask: n.byTask === true, compact: n.compact === true, landing };
}

// The task a screen sits under while grouped by task (undefined = one plain list, as before).
export function supervisorTaskOf(key: string, nav: SupervisorNav): SupervisorTask | undefined {
    return nav.byTask ? SUPERVISOR_TASK_OF[key] : undefined;
}

// The screen the Supervisor UI opens on: the landing when the supervisor may see it (for 'report' and 'review': the
// Department tab too, when tabs are given), else the first one (as before).
export function supervisorLanding(nav: SupervisorNav, available: ScreenKey[], tabs?: DeptTab[]): ScreenKey | undefined {
    if (nav.landing === 'first') return available[0];
    const want = LANDING_SCREEN[nav.landing];
    const tab = LANDING_TAB[nav.landing];
    if (tab && tabs && !tabs.includes(tab)) return available[0];
    return available.includes(want) ? want : available[0];
}
