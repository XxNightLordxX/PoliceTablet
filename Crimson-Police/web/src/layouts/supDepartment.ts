// The Department screen of the Supervisor UI (MG3): the supervisor's department tools as tabs of one screen.

// The Department screen of the Supervisor UI (MG3): the supervisor's department tools as tabs of one screen.
// Officers (the Department Report and each officer's actions), Controls (Mission controls with each control's admin
// limits and today's use inline), Review (the Review Queue), Restrictions (the mission bans and tablet suspensions of
// his department, admin/components/RestrictionsPanel.tsx), Calls & notices (the mission calls panel and the
// department notices) and Training (field training). A link to a tab is navigate('sup_department', { deptTab }).

// Above the tabs (UI4): today at a glance (todayTiles): officers on duty, runs going, waiting for review and the
// supervisor's Mission controls used today, each opening the tab or screen where he acts on it.
// Pure functions, checked by supDepartment.walk.ts: deptTabsFor (the tabs a session may see: each tab keeps the
// permission of the screen it replaces), deptTabOf (the tab the screen shows) and todayTiles.

import type { ScreenKey, ScreenParams } from '../shared/navigation';
import type { Session } from '../shared/types';
import type { SupToday } from '../types/oversight';

export type DeptTab = 'officers' | 'controls' | 'review' | 'restrictions' | 'calls' | 'training';
export const DEPT_TABS: DeptTab[] = ['officers', 'controls', 'review', 'restrictions', 'calls', 'training'];

const has = (s: Session, ...actions: string[]) => Array.isArray(s?.actions) && actions.some(a => s.actions.includes(a));

// Each tab's permission: the same as the screen or panel it replaces.
const TAB_VISIBLE: Record<DeptTab, (s: Session) => boolean> = {
    // Department Report: viewMissionList (every supervisor's)
    officers: s => has(s, 'viewMissionList'),
    // Mission controls: the master switch or a control outside it
    controls: s => has(s, 'missionControls') || s.config?.missionControls === true,
    review: s => has(s, 'reviewFlagged', 'handleDisputes'),
    // the mission bans and suspensions of his department (Config.MissionControls.restrictionsTab)
    restrictions: s => has(s, 'viewMissionList') && s.config?.restrictionsTab === true,
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

// ============================================================================
//                              TODAY AT A GLANCE
// ============================================================================

export type TodayKey = 'onDuty' | 'running' | 'review' | 'controls';
export interface TodayTile {
    key: TodayKey;
    // the number shown ('–' while sup:getToday has not answered)
    value: string;
    // amber: something waits (review items) or every control use of today is spent
    warn: boolean;
    // where a click goes (null: nowhere this supervisor may go)
    open: { screen: ScreenKey; deptTab?: DeptTab } | null;
}

// The tiles of today at a glance, in order. None without the Officers tab (viewMissionList, as sup:getToday); Waiting
// for review only with the Review tab; Your controls today only with a control that has a day count. review = the
// sidebar's Review Queue count (getNavCounts); screens = the Supervisor screens the session may see.
export function todayTiles(
    data: SupToday | null | undefined,
    review: number,
    tabs: DeptTab[],
    screens: ScreenKey[],
): TodayTile[] {
    if (!tabs.includes('officers')) return [];
    const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? String(Math.max(0, Math.floor(v))) : '–');
    const tab = (t: DeptTab) => (tabs.includes(t) ? { screen: 'sup_department' as ScreenKey, deptTab: t } : null);
    const out: TodayTile[] = [
        { key: 'onDuty', value: n(data?.onDuty), warn: false, open: tab('officers') },
        {
            key: 'running',
            value: n(data?.running),
            warn: false,
            open: screens.includes('sup_live') ? { screen: 'sup_live' } : null,
        },
    ];
    if (tabs.includes('review')) {
        out.push({ key: 'review', value: n(review), warn: review > 0, open: tab('review') });
    }
    const c = data?.controls;
    if (c && c.counted > 0 && c.perDay > 0) {
        out.push({
            key: 'controls',
            value: `${n(c.used)} / ${n(c.perDay)}`,
            warn: c.used >= c.perDay,
            open: tab('controls'),
        });
    }
    return out;
}
