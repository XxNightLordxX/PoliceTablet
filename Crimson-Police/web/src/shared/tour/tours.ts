// The guided tours (Config.Training): one step list per tablet. Each step points at one element (its data-tour id,

// The guided tours (Config.Training): one step list per tablet. Each step points at one element (its data-tour id,
// or 'screen-<head>' for a whole screen, 'nav-<screen key>' for a sidebar button, 'crim-nav-<screen>' for a criminal
// tablet tab), says what it is in one or two sentences (locale tour.<tour>.<step>.title and .body) and may open a
// screen first. 'since' is the tour version that added the step: the version of a tour is its highest 'since', and
// modules/access/training.lua (CP.Training.TOURS) carries the same number (shared/tour/tours.walk.ts checks both and
// that every target exists in the sources). Add a step with the next version: only the new steps show to a
// character who finished the tour before.

import type { ScreenKey, ScreenParams } from '../navigation';
import type { Session } from '../types';
import type { CrimScreen } from '../../types/criminal';

export type TourId = 'officer' | 'supervisor' | 'admin' | 'criminal';
export const TOUR_IDS: TourId[] = ['officer', 'supervisor', 'admin', 'criminal'];

// The tablet a tour runs in (the criminal tablet has no session).
export type TourTablet = 'officer' | 'supervisor' | 'admin' | 'criminal';

// What a step's needs() may look at: the session, the screens of the open UI, the Supervisor Department tabs and
// whether Admin UI -> Home shows the Setup checklist.
export interface TourCtx {
    session: Session | null;
    screens: string[];
    deptTabs: string[];
    // Config.Training.setupChecklist: Admin UI -> Home shows the Setup checklist
    checklist: boolean;
}

export interface TourStep {
    id: string;
    // data-tour id of the element it points at; none = a card in the middle of the screen
    target?: string;
    // the screen (and its params, e.g. a tab) to open first, in the Officer, Supervisor or Admin UI
    screen?: { key: ScreenKey; params?: ScreenParams };
    // the criminal tablet screen to open first
    crim?: CrimScreen;
    // 'click': the step moves on by itself once the officer clicks the element (Next still works)
    waitFor?: 'click';
    // the tour version that added the step (1 when left out)
    since?: number;
    // shown only when this is true (a screen or tab the player may not see is left out)
    needs?: (ctx: TourCtx) => boolean;
}

export interface TourDef {
    id: TourId;
    tablet: TourTablet;
    steps: TourStep[];
}

const hasScreen = (key: string) => (ctx: TourCtx) => ctx.screens.includes(key);
const hasTab = (tab: string) => (ctx: TourCtx) => ctx.deptTabs.includes(tab);
const dept = (deptTab: string) => ({ key: 'sup_department' as ScreenKey, params: { deptTab } });

export const TOURS: Record<TourId, TourDef> = {
    officer: {
        id: 'officer',
        tablet: 'officer',
        steps: [
            { id: 'welcome' },
            { id: 'status', target: 'officer-status', screen: { key: 'home' } },
            { id: 'board', target: 'nav-board', waitFor: 'click' },
            { id: 'accept', target: 'board-accept', screen: { key: 'board' } },
            { id: 'active', target: 'nav-active' },
            { id: 'unit', target: 'nav-unit' },
            { id: 'dispatch', target: 'nav-dispatch', needs: hasScreen('dispatch') },
            { id: 'me', target: 'nav-me' },
            { id: 'options', target: 'nav-options', needs: hasScreen('options') },
            { id: 'help', target: 'tour-help' },
        ],
    },
    supervisor: {
        id: 'supervisor',
        tablet: 'supervisor',
        steps: [
            { id: 'welcome' },
            { id: 'today', target: 'sup-today', screen: dept('officers'), needs: hasTab('officers') },
            { id: 'officers', target: 'screen-sup_report', screen: dept('officers'), needs: hasTab('officers') },
            { id: 'controls', target: 'screen-sup_controls', screen: dept('controls'), needs: hasTab('controls') },
            { id: 'review', target: 'screen-sup_review', screen: dept('review'), needs: hasTab('review') },
            { id: 'calls', target: 'screen-sup_calls', screen: dept('calls'), needs: hasTab('calls') },
            { id: 'training', target: 'screen-sup_training', screen: dept('training'), needs: hasTab('training') },
            { id: 'help', target: 'tour-help' },
        ],
    },
    admin: {
        id: 'admin',
        tablet: 'admin',
        steps: [
            { id: 'welcome' },
            { id: 'home', target: 'screen-admin_home', screen: { key: 'admin_home' }, needs: hasScreen('admin_home') },
            {
                id: 'checklist',
                target: 'admin-checklist',
                screen: { key: 'admin_home' },
                needs: ctx => ctx.checklist && ctx.screens.includes('admin_home'),
            },
            { id: 'search', target: 'admin-search' },
            { id: 'groups', target: 'sidebar' },
            { id: 'gear', target: 'admin-gear', screen: { key: 'admin_home' }, needs: hasScreen('admin_settings') },
            {
                id: 'presets',
                target: 'screen-admin_settings',
                screen: { key: 'admin_settings', params: { tab: 'presets' } },
                needs: hasScreen('admin_settings'),
            },
            { id: 'money', target: 'nav-admin_money', needs: hasScreen('admin_money') },
            {
                id: 'locks',
                target: 'screen-admin_settings',
                screen: { key: 'admin_settings', params: { tab: 'features' } },
                needs: hasScreen('admin_settings'),
            },
            { id: 'help', target: 'tour-help' },
        ],
    },
    criminal: {
        id: 'criminal',
        tablet: 'criminal',
        steps: [
            { id: 'welcome' },
            { id: 'optin', target: 'crim-optin', crim: 'home' },
            { id: 'jobs', target: 'crim-nav-jobs' },
            { id: 'consent', target: 'screen-crim_jobs', crim: 'jobs' },
            { id: 'rules', target: 'screen-crim_rules', crim: 'rules' },
            { id: 'strikes', target: 'screen-crim_history', crim: 'history' },
            { id: 'help', target: 'tour-help' },
        ],
    },
};

// The tour version: the highest 'since' of its steps.
export function tourVersion(tour: TourDef): number {
    return tour.steps.reduce((v, s) => Math.max(v, s.since ?? 1), 1);
}

// The tours a tablet offers (its '?' button starts the first; the Tours lists show them all).
export function toursOf(tablet: TourTablet): TourId[] {
    return TOUR_IDS.filter(id => TOURS[id].tablet === tablet);
}

// The steps to show: all of them (a replay), or only the ones added after the version the player finished; in
// either case only the steps whose needs() hold.
export function stepsToShow(tour: TourDef, seenVersion: number, full: boolean, ctx: TourCtx): TourStep[] {
    return tour.steps.filter(s => (full || (s.since ?? 1) > seenVersion) && (!s.needs || s.needs(ctx)));
}

export function stepTitleKey(tour: TourId, step: TourStep): string {
    return `tour.${tour}.${step.id}.title`;
}

export function stepBodyKey(tour: TourId, step: TourStep): string {
    return `tour.${tour}.${step.id}.body`;
}
