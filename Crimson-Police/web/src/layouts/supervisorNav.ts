// The Supervisor UI sidebar and landing (step G5): Config.Tablet.supervisorByTask (the screens grouped by task under
// People, Missions, Rewards and Review), supervisorCompact (icons only) and supervisorLanding (the screen it opens on).
// Only the layout changes: the same screens show, a hidden one stays hidden, keys and links stay the same.

import type { ScreenKey } from '../shared/navigation';
import type { Session } from '../shared/types';

export type SupervisorLanding = 'first' | 'report' | 'review' | 'live';
export type SupervisorNav = { byTask: boolean; compact: boolean; landing: SupervisorLanding };
export type SupervisorTask = 'people' | 'missions' | 'rewards' | 'review';

export const CLASSIC_SUP_NAV: SupervisorNav = { byTask: false, compact: false, landing: 'first' };

// The task headings in order (titles: ui.nav.task.<key>).
export const SUPERVISOR_TASKS: SupervisorTask[] = ['people', 'missions', 'rewards', 'review'];

// The task each Supervisor screen is listed under when the sidebar is grouped by task.
export const SUPERVISOR_TASK_OF: Record<string, SupervisorTask> = {
    sup_report: 'people',
    sup_missions: 'missions',
    sup_live: 'missions',
    sup_crossdept: 'missions',
    sup_controls: 'missions',
    sup_builder: 'missions',
    sup_payouts: 'rewards',
    sup_review: 'review',
};

const LANDING_SCREEN: Record<Exclude<SupervisorLanding, 'first'>, ScreenKey> = {
    report: 'sup_report',
    review: 'sup_review',
    live: 'sup_live',
};

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

// The screen the Supervisor UI opens on: the landing when the supervisor may see it, else the first one (as before).
export function supervisorLanding(nav: SupervisorNav, available: ScreenKey[]): ScreenKey | undefined {
    if (nav.landing === 'first') return available[0];
    const want = LANDING_SCREEN[nav.landing];
    return available.includes(want) ? want : available[0];
}
