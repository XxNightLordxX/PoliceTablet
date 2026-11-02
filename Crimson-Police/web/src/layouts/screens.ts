// The screen registry: sidebar order, titles, icons and visibility. Screen files are replaced by their owners; this
// registry (and the imports) never change.

import type { ComponentType } from 'react';
import type { IconName } from '../shared/components';
import type { AdminScreenKey, OfficerScreenKey, ScreenKey, SupervisorScreenKey } from '../shared/navigation';
import type { Session, UiKind } from '../shared/types';
import { supervisorLanding, supervisorNavOf } from './supervisorNav';

import Home from '../officer/screens/Home';
import MissionBoard from '../officer/screens/MissionBoard';
import Dispatch from '../officer/screens/Dispatch';
import Unit from '../officer/screens/Unit';
import ActiveMission from '../officer/screens/ActiveMission';
import Leaderboard from '../officer/screens/Leaderboard';
import Challenge from '../officer/screens/Challenge';
import Profile from '../officer/screens/Profile';
import MyOptions from '../officer/screens/MyOptions';

import SupMissionList from '../supervisor/screens/MissionList';
import SupCrossDept from '../supervisor/screens/CrossDept';
import SupLiveMissions from '../supervisor/screens/LiveMissions';
import SupReviewQueue from '../supervisor/screens/ReviewQueue';
import SupPayouts from '../supervisor/screens/Payouts';
import SupBuilder from '../supervisor/screens/Builder';
import SupDeptReport from '../supervisor/screens/DeptReport';
import SupMissionControls from '../supervisor/screens/MissionControls';

import AdminHome from '../admin/screens/Home';
import AdminPayouts from '../admin/screens/Payouts';
import AdminMissions from '../admin/screens/Missions';
import AdminSeasons from '../admin/screens/Seasons';
import AdminLeaderboards from '../admin/screens/Leaderboards';
import AdminOfficers from '../admin/screens/Officers';
import AdminDepartments from '../admin/screens/Departments';
import AdminPermissions from '../admin/screens/Permissions';
import AdminSettings from '../admin/screens/Settings';
import AdminAudit from '../admin/screens/Audit';
import AdminTesting from '../admin/screens/Testing';
import AdminLive from '../admin/screens/Live';
import AdminPayments from '../admin/screens/Payments';
import AdminSystem from '../admin/screens/System';
import AdminRealSuspects from '../admin/screens/RealSuspects';

export interface ScreenDef<K extends ScreenKey = ScreenKey> {
    key: K;
    // Locale key of the sidebar label and screen title: ui.screen.<key>.
    titleKey: string;
    icon: IconName;
    component: ComponentType;
    // Hidden when this returns false (permissions from session.actions).
    visible?: (session: Session) => boolean;
    // Admin sidebar (Config.AdminUi.groupSidebar): 'main' items always show, 'more' items fold under More.
    group?: 'main' | 'more';
    // Admin sidebar (Config.AdminUi.groupByPlay): the section it is listed under (PLAY_SECTIONS); none = on top
    play?: PlaySection;
}

// The sections of the Admin sidebar (Config.AdminUi.groupByPlay), in order: missions against NPCs, real players as
// suspects, officers working together, then money and the server. Titles: settings.features.play.<key>.
export type PlaySection = 'npc' | 'pvp' | 'team' | 'economy' | 'system';
export const PLAY_SECTIONS: PlaySection[] = ['npc', 'pvp', 'team', 'economy', 'system'];

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
    {
        key: 'options',
        titleKey: 'ui.screen.options',
        icon: 'sliders',
        component: MyOptions,
        visible: s => s.config?.officerOptions?.enabled !== false,
    },
];

export const SUPERVISOR_SCREENS: ScreenDef<SupervisorScreenKey>[] = [
    // viewMissionList: every supervisor's; an officer with only an admin's extra grant (Config.Permissions.grants, step
    // G1) sees just the screens of his powers
    {
        key: 'sup_missions',
        titleKey: 'ui.screen.sup_missions',
        icon: 'list',
        component: SupMissionList,
        visible: s => has(s, 'viewMissionList'),
    },
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
        visible: s => has(s, 'viewMissionList'),
    },
    {
        key: 'sup_controls',
        titleKey: 'ui.screen.sup_controls',
        icon: 'clock',
        component: SupMissionControls,
        visible: s => has(s, 'missionControls') || s.config?.missionControls === true,
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
    {
        key: 'sup_report',
        titleKey: 'ui.screen.sup_report',
        icon: 'barChart',
        component: SupDeptReport,
        // fieldTraining alone: the screen shows only its Field training panel
        visible: s => has(s, 'viewMissionList', 'fieldTraining'),
    },
];

// Config.AdminUi.landing: 'home' (or a session without it) shows Home; 'payouts' or 'missions' hide it.
const adminLanding = (s: Session) => s.config?.adminUi?.landing ?? 'home';

export const ADMIN_SCREENS: ScreenDef<AdminScreenKey>[] = [
    {
        key: 'admin_home',
        titleKey: 'ui.screen.admin_home',
        icon: 'home',
        component: AdminHome,
        visible: s => adminLanding(s) === 'home',
        group: 'main',
    },
    {
        key: 'admin_payouts',
        titleKey: 'ui.screen.admin_payouts',
        icon: 'dollar',
        component: AdminPayouts,
        play: 'economy',
        group: 'main',
    },
    {
        key: 'admin_payments',
        titleKey: 'ui.screen.admin_payments',
        icon: 'creditCard',
        component: AdminPayments,
        play: 'economy',
        group: 'more',
    },
    {
        key: 'admin_missions',
        titleKey: 'ui.screen.admin_missions',
        icon: 'layers',
        component: AdminMissions,
        play: 'npc',
        group: 'main',
    },
    {
        key: 'admin_live',
        titleKey: 'ui.screen.admin_live',
        icon: 'activity',
        component: AdminLive,
        play: 'npc',
        group: 'main',
    },
    {
        key: 'admin_seasons',
        titleKey: 'ui.screen.admin_seasons',
        icon: 'calendar',
        component: AdminSeasons,
        play: 'team',
        group: 'more',
    },
    {
        key: 'admin_leaderboards',
        titleKey: 'ui.screen.admin_leaderboards',
        icon: 'podium',
        component: AdminLeaderboards,
        play: 'team',
        group: 'more',
    },
    {
        key: 'admin_officers',
        titleKey: 'ui.screen.admin_officers',
        icon: 'search',
        component: AdminOfficers,
        play: 'team',
        group: 'main',
    },
    {
        key: 'admin_departments',
        titleKey: 'ui.screen.admin_departments',
        icon: 'building',
        component: AdminDepartments,
        play: 'team',
        group: 'more',
    },
    {
        key: 'admin_permissions',
        titleKey: 'ui.screen.admin_permissions',
        icon: 'key',
        component: AdminPermissions,
        play: 'team',
        group: 'more',
    },
    {
        key: 'admin_settings',
        titleKey: 'ui.screen.admin_settings',
        icon: 'sliders',
        component: AdminSettings,
        play: 'system',
        group: 'main',
    },
    {
        // Real suspects (step V18): while live crimes or volunteers are on (Config.RealSuspects.adminScreen)
        key: 'admin_rs',
        titleKey: 'ui.screen.admin_rs',
        icon: 'shield',
        component: AdminRealSuspects,
        visible: s => has(s, 'antiFarmOverride') && s.config?.realSuspects?.screen === true,
        play: 'pvp',
        group: 'more',
    },
    {
        key: 'admin_system',
        titleKey: 'ui.screen.admin_system',
        icon: 'server',
        component: AdminSystem,
        play: 'system',
        group: 'more',
    },
    {
        key: 'admin_audit',
        titleKey: 'ui.screen.admin_audit',
        icon: 'fileText',
        component: AdminAudit,
        play: 'system',
        group: 'more',
    },
    {
        key: 'admin_testing',
        titleKey: 'ui.screen.admin_testing',
        icon: 'flask',
        component: AdminTesting,
        play: 'system',
        group: 'more',
    },
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

// The screen a UI opens on while its remembered screen is not one it shows: the first one, except the Admin UI
// opens on Config.AdminUi.landing (Home, Payouts or Missions) and the Supervisor UI on Config.Tablet.supervisorLanding.
export function landingScreen(ui: UiKind, session: Session | null, available: ScreenKey[]): ScreenKey {
    if (ui === 'admin' && session) {
        const want = `admin_${adminLanding(session)}` as ScreenKey;
        if (available.includes(want)) return want;
    }
    // Config.Tablet.supervisorLanding (step G5): 'first' = as before
    if (ui === 'supervisor') return supervisorLanding(supervisorNavOf(session), available) ?? 'home';
    return available[0] ?? 'home';
}

// The screen a UI shows: the remembered one while it is shown, else the landing. The Supervisor UI opens on its landing
// (Config.Tablet.supervisorLanding, step G5) until a screen is picked; with 'first' that is the same screen as before.
export function currentScreen(
    ui: UiKind,
    session: Session | null,
    available: ScreenKey[],
    current: { key: ScreenKey; picked?: boolean } | null | undefined,
): ScreenKey {
    const keep = !!current && available.includes(current.key) && (ui !== 'supervisor' || current.picked === true);
    return keep && current ? current.key : landingScreen(ui, session, available);
}
