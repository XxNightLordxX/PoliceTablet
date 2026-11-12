// The Officer UI with fewer screens: the Me screen's tabs, Home's next step and the run bar's quick links.

// The Officer UI with fewer screens: the Me screen's tabs, Home's next step and the run bar's quick links.
// The Me screen holds Profile & History, Leaderboard and Department Challenge as tabs of one screen; Home's next step
// is the officer's status, his next goal and one big button; the run bar links to Mission Board, Dispatch and Unit
// while on a run. A link to a Me tab is navigate('me', { meTab }); an officer's public profile is
// navigate('me', { meTab: 'profile', citizenid }).
// Pure functions, checked by officerMe.walk.ts.

import type { ScreenKey, ScreenParams } from '../shared/navigation';
import type { Goal } from '../shared/types';

// ============================================================================
//                                      ME
// ============================================================================

export type MeTab = 'profile' | 'leaderboard' | 'challenge';
export const ME_TABS: MeTab[] = ['profile', 'leaderboard', 'challenge'];

// The tab the Me screen shows: the asked one, else Profile (an officer's profile is a Profile link).
export function meTabOf(params: ScreenParams | null | undefined): MeTab {
    const asked = params?.meTab;
    if (typeof asked === 'string' && (ME_TABS as string[]).includes(asked)) return asked as MeTab;
    return 'profile';
}

// The navigate('me', ...) params of a tab, with the officer whose profile opens (none = the own one).
export function meLink(tab: MeTab, citizenid?: string | null): ScreenParams {
    return typeof citizenid === 'string' && citizenid !== '' ? { meTab: tab, citizenid } : { meTab: tab };
}

// ============================================================================
//                               HOME: NEXT STEP
// ============================================================================

export type HomeStatus = 'run' | 'limit' | 'ready';
export interface HomeNext {
    // on a run; the day's mission limit reached (Config run limits); ready for a mission
    status: HomeStatus;
    // the goal to work on next: today's while it is not done, else this week's (null: none set or both done)
    goal: { kind: 'daily' | 'weekly'; goal: Goal } | null;
    // both goals set and done
    allDone: boolean;
    // the big button: Active Mission on a run, else the Mission Board
    open: ScreenKey;
}

export function homeNext(
    goals: { daily?: Goal | null; weekly?: Goal | null } | null | undefined,
    missionsToday: { n: number; max: number } | null | undefined,
    onRun: boolean,
): HomeNext {
    const limit = !!missionsToday && missionsToday.max > 0 && missionsToday.n >= missionsToday.max;
    const status: HomeStatus = onRun ? 'run' : limit ? 'limit' : 'ready';
    const daily = goals?.daily ?? null;
    const weekly = goals?.weekly ?? null;
    let goal: HomeNext['goal'] = null;
    if (daily && !daily.done) goal = { kind: 'daily', goal: daily };
    else if (weekly && !weekly.done) goal = { kind: 'weekly', goal: weekly };
    const set = [daily, weekly].filter((g): g is Goal => !!g);
    return { status, goal, allDone: set.length > 0 && set.every(g => g.done), open: onRun ? 'active' : 'board' };
}

// ============================================================================
//                                RUN BAR LINKS
// ============================================================================

// The screens the run bar links to while on a run, in order: the ones the officer's UI shows (Dispatch hides with
// Config.MissionCalls off), never the screen he is on.
const RUN_LINKS: ScreenKey[] = ['board', 'dispatch', 'unit'];

export function runBarLinks(available: ScreenKey[], current: ScreenKey): ScreenKey[] {
    return RUN_LINKS.filter(k => available.includes(k) && k !== current);
}
