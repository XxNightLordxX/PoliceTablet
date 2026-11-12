// The Officer UI with fewer screens (UI5) against the browser mocks (node walk.mjs, a gate step).

// The Officer UI with fewer screens (UI5) against the browser mocks (node walk.mjs, a gate step).
// The sidebar has one Me screen (Profile & History, Leaderboard and Department Challenge as its tabs) in place of three,
// every old link opens its tab, Home shows the status, the next goal and one big button, and the run bar links to
// Mission Board, Dispatch and Unit.

import '../mocks/core.mock';
import { request } from '../shared/nui';
import { SCREEN_HEADS, TABBED_SCREENS } from '../shared/screenHeads';
import type { Goal, Session } from '../shared/types';
import challengeSrc from '../officer/screens/Challenge.tsx?raw';
import homeSrc from '../officer/screens/Home.tsx?raw';
import leaderboardSrc from '../officer/screens/Leaderboard.tsx?raw';
import meSrc from '../officer/screens/Me.tsx?raw';
import profileSrc from '../officer/screens/Profile.tsx?raw';
import runBarSrc from './RunBar.tsx?raw';
import { navBadge, EMPTY_COUNTS } from './navBadges';
import { ME_TABS, homeNext, meLink, meTabOf, runBarLinks } from './officerMe';
import { OFFICER_SCREENS, screensFor } from './screens';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const goal = (done: boolean, label = 'Do 2 runs'): Goal =>
    ({ label, count: 2, progress: done ? 2 : 1, points: 50, done }) as Goal;

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

async function steps(): Promise<void> {
    // one Me screen in place of Profile, Leaderboard and Challenge; nothing else lost
    const keys = OFFICER_SCREENS.map(s => s.key).join(',');
    ok(keys === 'home,board,dispatch,unit,active,me,options', `the officer sidebar: ${keys}`);
    const res = await request<Session>('getSession', { ui: 'officer' });
    ok(res.ok && screensFor('officer', res.data ?? null).some(s => s.key === 'me'), 'the mock session shows Me');
    ok(ME_TABS.join(',') === 'profile,leaderboard,challenge', 'Me: the three tabs, Profile first');
    ok(TABBED_SCREENS.includes('me'), 'Me has no head of its own');
    for (const k of ME_TABS) ok(SCREEN_HEADS[k], `${k}: its tab keeps its head`);
    ok(meSrc.includes('<Profile') && meSrc.includes('<Leaderboard') && meSrc.includes('<Challenge'), 'Me renders all');
    ok(navBadge('me', { ...EMPTY_COUNTS, commendations: 3 }).badge === '3', 'Me: the commendations badge');

    // every old link opens its tab
    ok(meTabOf(null) === 'profile' && meTabOf({}) === 'profile', 'no tab: Profile');
    ok(meTabOf({ meTab: 'challenge' }) === 'challenge', 'a tab link opens its tab');
    ok(meTabOf({ meTab: 'bogus' }) === 'profile', 'an unknown tab: Profile');
    ok(meTabOf(meLink('profile', 'ABC123')) === 'profile', 'an officer link opens Profile');
    ok(meLink('profile', 'ABC123').citizenid === 'ABC123', 'an officer link carries the officer');
    ok(meLink('profile', null).citizenid === undefined && meLink('profile', '').citizenid === undefined, 'own: none');
    for (const [name, src] of [
        ['Profile', profileSrc],
        ['Leaderboard', leaderboardSrc],
        ['Challenge', challengeSrc],
    ] as const) {
        ok(!/navigate\('(profile|leaderboard|challenge)'/.test(src), `${name}: no link to an old screen key`);
    }
    ok(leaderboardSrc.includes("navigate('me', meLink('profile'"), 'Leaderboard rows open the Profile tab');
    ok(profileSrc.includes("navigate('me', meLink('leaderboard'))"), 'Profile Back opens the Leaderboard tab');

    // Home: status, next goal and one big button
    const ready = homeNext({ daily: goal(false), weekly: goal(false, 'Week') }, { n: 1, max: 5 }, false);
    ok(ready.status === 'ready' && ready.open === 'board', 'ready: Find a mission opens the Mission Board');
    ok(ready.goal?.kind === 'daily' && ready.goal.goal.label === 'Do 2 runs', "next goal: today's first");
    const week = homeNext({ daily: goal(true), weekly: goal(false, 'Week') }, null, false);
    ok(week.goal?.kind === 'weekly' && !week.allDone, "today's done: this week's next");
    const done = homeNext({ daily: goal(true), weekly: goal(true) }, null, false);
    ok(done.goal === null && done.allDone, 'both done');
    const none = homeNext(null, undefined, false);
    ok(none.goal === null && !none.allDone && none.status === 'ready', 'no goals: none, ready');
    ok(homeNext(null, { n: 5, max: 5 }, false).status === 'limit', "the day's missions done: limit");
    ok(homeNext(null, { n: 5, max: 0 }, false).status === 'ready', 'no day limit: ready');
    const run = homeNext(null, { n: 5, max: 5 }, true);
    ok(run.status === 'run' && run.open === 'active', 'on a run: Back to your mission');
    ok(!homeSrc.includes("'officer.home.open_board'"), 'Home: one big button, no second Mission Board button');
    ok(homeSrc.includes('<NextStep'), 'Home shows the next step');

    // the run bar links: the screens the UI shows, never the one open
    ok(
        runBarLinks(['home', 'board', 'dispatch', 'unit', 'active'], 'active').join(',') === 'board,dispatch,unit',
        'all',
    );
    ok(runBarLinks(['home', 'board', 'unit', 'active'], 'active').join(',') === 'board,unit', 'Dispatch hidden');
    ok(runBarLinks(['home', 'board', 'dispatch', 'unit'], 'unit').join(',') === 'board,dispatch', 'not the open one');
    ok(runBarSrc.includes('cp-runbar__links') && runBarSrc.includes("navigate('active')"), 'the bar keeps its link');
}
