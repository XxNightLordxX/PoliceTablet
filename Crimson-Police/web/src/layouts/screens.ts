// The screen registry: sidebar order, titles, icons and visibility. Screen files are replaced by their owners; this
// registry (and the imports) never change.

import type { ComponentType } from 'react';
import type { IconName } from '../shared/components';
import type { AdminScreenKey, OfficerScreenKey, ScreenKey, SupervisorScreenKey } from '../shared/navigation';
import type { Session, UiKind } from '../shared/types';

import Home from '../officer/screens/Home';
import MissionBoard from '../officer/screens/MissionBoard';
import Dispatch from '../officer/screens/Dispatch';
import Unit from '../officer/screens/Unit';
import ActiveMission from '../officer/screens/ActiveMission';
import Leaderboard from '../officer/screens/Leaderboard';
import Challenge from '../officer/screens/Challenge';
import Profile from '../officer/screens/Profile';

import SupMissionList from '../supervisor/screens/MissionList';
import SupCrossDept from '../supervisor/screens/CrossDept';
import SupLiveMissions from '../supervisor/screens/LiveMissions';
import SupReviewQueue from '../supervisor/screens/ReviewQueue';
import SupPayouts from '../supervisor/screens/Payouts';
import SupBuilder from '../supervisor/screens/Builder';
import SupDeptReport from '../supervisor/screens/DeptReport';

import AdminPayouts from '../admin/screens/Payouts';
import AdminMissions from '../admin/screens/Missions';
import AdminSeasons from '../admin/screens/Seasons';
import AdminLeaderboards from '../admin/screens/Leaderboards';
import AdminOfficers from '../admin/screens/Officers';
import AdminDepartments from '../admin/screens/Departments';
import AdminPermissions from '../admin/screens/Permissions';
import AdminAudit from '../admin/screens/Audit';
import AdminTesting from '../admin/screens/Testing';

export interface ScreenDef<K extends ScreenKey = ScreenKey> {
    key: K;
    // Locale key of the sidebar label and screen title: ui.screen.<key>.
    titleKey: string;
    icon: IconName;
    component: ComponentType;
    // Hidden when this returns false (permissions from session.actions).
    visible?: (session: Session) => boolean;
}

const has = (s: Session, ...actions: string[]) => Array.isArray(s.actions) && actions.some(a => s.actions.includes(a));

export const OFFICER_SCREENS: ScreenDef<OfficerScreenKey>[] = [
    { key: 'home', titleKey: 'ui.screen.home', icon: 'home', component: Home },
    { key: 'board', titleKey: 'ui.screen.board', icon: 'board', component: MissionBoard },
    {
        key: 'dispatch',
        titleKey: 'ui.screen.dispatch',
        icon: 'radio',
        component: Dispatch,
        visible: s => s.config?.dispatch?.enabled !== false,
    },
    { key: 'unit', titleKey: 'ui.screen.unit', icon: 'users', component: Unit },
    { key: 'active', titleKey: 'ui.screen.active', icon: 'target', component: ActiveMission },
    { key: 'leaderboard', titleKey: 'ui.screen.leaderboard', icon: 'trophy', component: Leaderboard },
    { key: 'challenge', titleKey: 'ui.screen.challenge', icon: 'flag', component: Challenge },
    { key: 'profile', titleKey: 'ui.screen.profile', icon: 'user', component: Profile },
];

export const SUPERVISOR_SCREENS: ScreenDef<SupervisorScreenKey>[] = [
    { key: 'sup_missions', titleKey: 'ui.screen.sup_missions', icon: 'list', component: SupMissionList },
    {
        key: 'sup_crossdept',
        titleKey: 'ui.screen.sup_crossdept',
        icon: 'globe',
        component: SupCrossDept,
        visible: s => has(s, 'launchCrossDept'),
    },
    {
        key: 'sup_live',
        titleKey: 'ui.screen.sup_live',
        icon: 'activity',
        component: SupLiveMissions,
    },
    {
        key: 'sup_review',
        titleKey: 'ui.screen.sup_review',
        icon: 'shieldCheck',
        component: SupReviewQueue,
        visible: s => has(s, 'reviewFlagged', 'handleDisputes'),
    },
    {
        key: 'sup_payouts',
        titleKey: 'ui.screen.sup_payouts',
        icon: 'dollar',
        component: SupPayouts,
        visible: s => has(s, 'setTypePayout'),
    },
    {
        key: 'sup_builder',
        titleKey: 'ui.screen.sup_builder',
        icon: 'tool',
        component: SupBuilder,
        visible: s => has(s, 'builderEdit'),
    },
    { key: 'sup_report', titleKey: 'ui.screen.sup_report', icon: 'barChart', component: SupDeptReport },
];

export const ADMIN_SCREENS: ScreenDef<AdminScreenKey>[] = [
    { key: 'admin_payouts', titleKey: 'ui.screen.admin_payouts', icon: 'dollar', component: AdminPayouts },
    { key: 'admin_missions', titleKey: 'ui.screen.admin_missions', icon: 'layers', component: AdminMissions },
    { key: 'admin_seasons', titleKey: 'ui.screen.admin_seasons', icon: 'calendar', component: AdminSeasons },
    {
        key: 'admin_leaderboards',
        titleKey: 'ui.screen.admin_leaderboards',
        icon: 'podium',
        component: AdminLeaderboards,
    },
    { key: 'admin_officers', titleKey: 'ui.screen.admin_officers', icon: 'search', component: AdminOfficers },
    {
        key: 'admin_departments',
        titleKey: 'ui.screen.admin_departments',
        icon: 'building',
        component: AdminDepartments,
    },
    { key: 'admin_permissions', titleKey: 'ui.screen.admin_permissions', icon: 'key', component: AdminPermissions },
    { key: 'admin_audit', titleKey: 'ui.screen.admin_audit', icon: 'fileText', component: AdminAudit },
    { key: 'admin_testing', titleKey: 'ui.screen.admin_testing', icon: 'flask', component: AdminTesting },
];

const ALL: Record<UiKind, ScreenDef[]> = {
    officer: OFFICER_SCREENS,
    supervisor: SUPERVISOR_SCREENS,
    admin: ADMIN_SCREENS,
};

// Screens of a UI the session may see, in sidebar order.
export function screensFor(ui: UiKind, session: Session | null): ScreenDef[] {
    const list = ALL[ui] ?? [];
    if (!session) return list.filter(s => !s.visible);
    return list.filter(s => !s.visible || s.visible(session));
}

export function defaultScreen(ui: UiKind): ScreenKey {
    return (ALL[ui]?.[0]?.key ?? 'home') as ScreenKey;
}
