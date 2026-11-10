// The Department screen of the Supervisor UI (MG3): the supervisor's department tools as tabs of one screen.

// The Department screen of the Supervisor UI (MG3): the supervisor's department tools as tabs of one screen.
// Officers (the Department Report and each officer's actions), Controls (Mission controls with each control's admin
// limits and today's use inline), Review (the Review Queue), Calls & notices (the mission calls panel and the
// department notices) and Training (field training). A link to a tab is navigate('sup_department', { deptTab }).

// Pure functions, checked by supDepartment.walk.ts: deptTabsFor (the tabs a session may see: each tab keeps the permission of the screen it replaces) and
// deptTabOf (the tab the screen shows).

import type { ScreenParams } from '../shared/navigation';
import type { Session } from '../shared/types';

export type DeptTab = 'officers' | 'controls' | 'review' | 'calls' | 'training';
export const DEPT_TABS: DeptTab[] = ['officers', 'controls', 'review', 'calls', 'training'];

const has = (s: Session, ...actions: string[]) => Array.isArray(s?.actions) && actions.some(a => s.actions.includes(a));

// Each tab's permission: the same as the screen or panel it replaces.
const TAB_VISIBLE: Record<DeptTab, (s: Session) => boolean> = {
    // Department Report: viewMissionList (every supervisor's)
    officers: s => has(s, 'viewMissionList'),
    // Mission controls: the master switch or a control outside it
    controls: s => has(s, 'missionControls') || s.config?.missionControls === true,
    review: s => has(s, 'reviewFlagged', 'handleDisputes'),
    // the mission calls panel (missionCalls) or the department notices (a Mission control)
    calls: s => has(s, 'missionCalls', 'missionControls') || s.config?.missionControls === true,
    // Field training: every supervisor, or an officer an admin granted only field training
    training: s => has(s, 'viewMissionList', 'fieldTraining'),
};

// The tabs the session may see, in screen order (none = no Department screen).
export function deptTabsFor(session: Session | null | undefined): DeptTab[] {
    if (!session) return [];
    return DEPT_TABS.filter(k => TAB_VISIBLE[k](session));
}

// The tab the screen shows: the asked one when the session may see it; else Review with Config.Tablet.supervisorLanding
// 'review' (the screen the Supervisor UI opens on); else the first tab the session may see.
export function deptTabOf(params: ScreenParams | null | undefined, session: Session | null | undefined): DeptTab {
    const tabs = deptTabsFor(session);
    const asked = params?.deptTab;
    if (typeof asked === 'string' && (tabs as string[]).includes(asked)) return asked as DeptTab;
    if (session?.config?.supervisorNav?.landing === 'review' && tabs.includes('review')) return 'review';
    return tabs[0] ?? 'officers';
}
