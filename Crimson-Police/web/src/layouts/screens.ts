// The screen registry: sidebar order, titles, icons and visibility. Screen files are replaced by their owners; this
// registry (and the imports) never change.

import { lazy, type ComponentType, type LazyExoticComponent } from 'react';
import type { IconName } from '../shared/components';
import type { AdminScreenKey, OfficerScreenKey, ScreenKey, SupervisorScreenKey } from '../shared/navigation';
import type { Session, UiKind } from '../shared/types';
import { deptTabsFor } from './supDepartment';
import { supervisorLanding, supervisorNavOf } from './supervisorNav';

import Home from '../officer/screens/Home';
import MissionBoard from '../officer/screens/MissionBoard';
import Dispatch from '../officer/screens/Dispatch';
import Unit from '../officer/screens/Unit';
import ActiveMission from '../officer/screens/ActiveMission';
import Me from '../officer/screens/Me';
import MyOptions from '../officer/screens/MyOptions';

import SupMissionList from '../supervisor/screens/MissionList';
import SupCrossDept from '../supervisor/screens/CrossDept';
import SupLiveMissions from '../supervisor/screens/LiveMissions';
import SupPayouts from '../supervisor/screens/Payouts';
import SupDepartment from '../supervisor/screens/Department';

// The Admin UI screens and the Supervisor Mission Builder load on first use: every player's NUI starts
// without them (most players never open them). Opening that UI starts loading all of its screens at once
// (preloadScreens), so a screen picked later is already there.
type Loader = () => Promise<{ default: ComponentType }>;
const LOADERS: Record<UiKind, Loader[]> = { officer: [], supervisor: [], admin: [] };
function lazyScreen(ui: UiKind, load: Loader): LazyExoticComponent<ComponentType> {
    LOADERS[ui].push(load);
    return lazy(load);
}

// Start loading every screen of that UI that loads on first use (a load that fails is tried again on render).
export function preloadScreens(ui: UiKind): void {
    for (const load of LOADERS[ui]) void load().catch(() => undefined);
}

const SupBuilder = lazyScreen('supervisor', () => import('../supervisor/screens/Builder'));
const AdminHome = lazyScreen('admin', () => import('../admin/screens/Home'));
const AdminMissions = lazyScreen('admin', () => import('../admin/screens/Missions'));
const AdminSeasons = lazyScreen('admin', () => import('../admin/screens/Seasons'));
const AdminLeaderboards = lazyScreen('admin', () => import('../admin/screens/Leaderboards'));
const AdminOfficers = lazyScreen('admin', () => import('../admin/screens/Officers'));
const AdminDepartments = lazyScreen('admin', () => import('../admin/screens/Departments'));
const AdminPermissions = lazyScreen('admin', () => import('../admin/screens/Permissions'));
const AdminSettings = lazyScreen('admin', () => import('../admin/screens/Settings'));
const AdminAudit = lazyScreen('admin', () => import('../admin/screens/Audit'));
const AdminTesting = lazyScreen('admin', () => import('../admin/screens/Testing'));
const AdminLive = lazyScreen('admin', () => import('../admin/screens/Live'));
const AdminSystem = lazyScreen('admin', () => import('../admin/screens/System'));
const AdminRealSuspects = lazyScreen('admin', () => import('../admin/screens/RealSuspects'));
const AdminMoney = lazyScreen('admin', () => import('../admin/screens/Money'));
const AdminMapMarkers = lazyScreen('admin', () => import('../admin/screens/MapMarkers'));
const AdminReview = lazyScreen('admin', () => import('../admin/screens/Review'));

export interface ScreenDef<K extends ScreenKey = ScreenKey> {
    key: K;
    // Locale key of the sidebar label and screen title: ui.screen.<key>.
    titleKey: string;
    icon: IconName;
    component: ComponentType | LazyExoticComponent<ComponentType>;
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
    // Me: Profile & History, Leaderboard and Department Challenge as three tabs (layouts/officerMe.ts)
    { key: 'me', titleKey: 'ui.screen.me', icon: 'user', component: Me },
    {
        key: 'options',
        titleKey: 'ui.screen.options',
        icon: 'sliders',
        component: MyOptions,
        visible: s => s.config?.officerOptions?.enabled !== false,
    },
];

export const SUPERVISOR_SCREENS: ScreenDef<SupervisorScreenKey>[] = [
    // viewMissionList: every supervisor's; an officer with only an admin's extra grant (Config.Permissions.grants)
    // sees just the screens of his powers
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
        visible: s => has(s, 'viewMissionList', 'forceRecall'),
    },
    // MG3: one Department screen: Officers (the Department Report), Controls (Mission controls), Review (the Review
    // Queue), Calls & notices and Training, each tab with the permission of the screen it replaces
    // (layouts/supDepartment.ts)
    {
        key: 'sup_department',
        titleKey: 'ui.screen.sup_department',
        icon: 'building',
        component: SupDepartment,
        visible: s => deptTabsFor(s).length > 0,
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
];

export const ADMIN_SCREENS: ScreenDef<AdminScreenKey>[] = [
    // Sidebar order: Home, then by job (layouts/adminNav.ts ADMIN_GROUPS): People, Missions, Real players, Money,
    // Review, System
    {
        key: 'admin_home',
        titleKey: 'ui.screen.admin_home',
        icon: 'home',
        component: AdminHome,
    },
    {
        key: 'admin_officers',
        titleKey: 'ui.screen.admin_officers',
        icon: 'search',
        component: AdminOfficers,
    },
    {
        key: 'admin_departments',
        titleKey: 'ui.screen.admin_departments',
        icon: 'building',
        component: AdminDepartments,
    },
    {
        key: 'admin_permissions',
        titleKey: 'ui.screen.admin_permissions',
        icon: 'key',
        component: AdminPermissions,
    },
    {
        key: 'admin_leaderboards',
        titleKey: 'ui.screen.admin_leaderboards',
        icon: 'podium',
        component: AdminLeaderboards,
    },
    {
        key: 'admin_seasons',
        titleKey: 'ui.screen.admin_seasons',
        icon: 'calendar',
        component: AdminSeasons,
    },
    {
        key: 'admin_missions',
        titleKey: 'ui.screen.admin_missions',
        icon: 'layers',
        component: AdminMissions,
    },
    {
        key: 'admin_live',
        titleKey: 'ui.screen.admin_live',
        icon: 'activity',
        component: AdminLive,
    },
    {
        // Map markers: the objective's look and every part of a mission
        key: 'admin_markers',
        titleKey: 'ui.screen.admin_markers',
        icon: 'mapPin',
        component: AdminMapMarkers,
    },
    {
        key: 'admin_testing',
        titleKey: 'ui.screen.admin_testing',
        icon: 'flask',
        component: AdminTesting,
    },
    {
        // Real suspects: while live crimes or volunteers are on (Config.RealSuspects.adminScreen)
        key: 'admin_rs',
        titleKey: 'ui.screen.admin_rs',
        icon: 'shield',
        component: AdminRealSuspects,
        visible: s => has(s, 'antiFarmOverride') && s.config?.realSuspects?.screen === true,
    },
    {
        // Money: Pay rates, Rewards, Payments and Department funds as four tabs (layouts/adminMoney.ts)
        key: 'admin_money',
        titleKey: 'ui.screen.admin_money',
        icon: 'dollar',
        component: AdminMoney,
    },
    {
        // Review: Flagged runs, Profiles, Disputes and Corrections as four tabs (admin/screens/Review.tsx)
        key: 'admin_review',
        titleKey: 'ui.screen.admin_review',
        icon: 'eye',
        component: AdminReview,
    },
    {
        key: 'admin_audit',
        titleKey: 'ui.screen.admin_audit',
        icon: 'fileText',
        component: AdminAudit,
    },
    {
        key: 'admin_settings',
        titleKey: 'ui.screen.admin_settings',
        icon: 'sliders',
        component: AdminSettings,
    },
    {
        key: 'admin_system',
        titleKey: 'ui.screen.admin_system',
        icon: 'server',
        component: AdminSystem,
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

// The screen a UI opens on while its remembered screen is not one it shows: the first one (the Admin UI's Home),
// except the Supervisor UI opens on Config.Tablet.supervisorLanding.
export function landingScreen(ui: UiKind, session: Session | null, available: ScreenKey[]): ScreenKey {
    // Config.Tablet.supervisorLanding: 'first' = as before
    if (ui === 'supervisor')
        return supervisorLanding(supervisorNavOf(session), available, deptTabsFor(session)) ?? 'home';
    return available[0] ?? 'home';
}

// The screen a UI shows: the remembered one while it is shown, else the landing. The Supervisor UI opens on its landing
// (Config.Tablet.supervisorLanding) until a screen is picked; with 'first' that is the same screen as before.
export function currentScreen(
    ui: UiKind,
    session: Session | null,
    available: ScreenKey[],
    current: { key: ScreenKey; picked?: boolean } | null | undefined,
): ScreenKey {
    const keep = !!current && available.includes(current.key) && (ui !== 'supervisor' || current.picked === true);
    return keep && current ? current.key : landingScreen(ui, session, available);
}
