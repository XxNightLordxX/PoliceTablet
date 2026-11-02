// Officer UI sidebar order (step G4) against the browser mocks (node walk.mjs, a gate step): Config.Tablet's
// sidebarOrder, activeFirst and compactSidebar reach the sidebar as the session's config.officerNav, and the order
// changes only when they are set.

import '../mocks/core.mock';
import { request } from '../shared/nui';
import type { Session } from '../shared/types';
import { CLASSIC_NAV, officerNavOf, orderOfficerScreens } from './officerNav';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const CLASSIC = ['home', 'board', 'dispatch', 'unit', 'active', 'leaderboard', 'challenge', 'profile', 'options'];
const keys = (list: { key: string }[]) => list.map(s => s.key).join(',');
const screens = (list: string[]) => list.map(key => ({ key }));

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

async function steps(): Promise<void> {
    const res = await request<Session>('getSession', { ui: 'officer' });
    ok(res.ok, 'getSession answers');
    const nav = officerNavOf(res.data);
    ok(nav.order === 'classic' && !nav.activeFirst && !nav.compact, 'the mock session ships the sidebar as before');
    ok(officerNavOf(null) === CLASSIC_NAV, 'no session: as before');
    ok(
        officerNavOf({ config: { officerNav: { order: 'bogus' } } } as unknown as Session).order === 'classic',
        'an unknown order counts as classic',
    );

    const all = screens(CLASSIC);
    ok(keys(orderOfficerScreens(all, CLASSIC_NAV, false)) === CLASSIC.join(','), 'classic: the registry order');
    ok(keys(orderOfficerScreens(all, CLASSIC_NAV, true)) === CLASSIC.join(','), 'classic on a run: unchanged');

    const most = { ...CLASSIC_NAV, order: 'mostUsed' as const };
    ok(
        keys(orderOfficerScreens(all, most, false)) ===
            'home,board,active,dispatch,unit,profile,leaderboard,challenge,options',
        'mostUsed: the common path first',
    );
    // Dispatch and My options hidden (MissionCalls or OfficerOptions off): the rest keep the mostUsed order
    const some = screens(CLASSIC.filter(k => k !== 'dispatch' && k !== 'options'));
    ok(
        keys(orderOfficerScreens(some, most, false)) === 'home,board,active,unit,profile,leaderboard,challenge',
        'a hidden screen stays hidden',
    );
    ok(
        keys(orderOfficerScreens(screens([...CLASSIC, 'extra']), most, false)).endsWith(',options,extra'),
        'a screen the order does not name keeps its place after the named ones',
    );

    const first = { ...CLASSIC_NAV, activeFirst: true };
    ok(keys(orderOfficerScreens(all, first, false)) === CLASSIC.join(','), 'activeFirst off a run: as before');
    ok(
        keys(orderOfficerScreens(all, first, true)) ===
            'home,active,board,dispatch,unit,leaderboard,challenge,profile,options',
        'activeFirst on a run: under Home',
    );
    ok(
        keys(orderOfficerScreens(screens(CLASSIC.slice(1)), first, true)).startsWith('active,board'),
        'no Home: Active Mission on top',
    );
    ok(orderOfficerScreens(all, first, true) !== all && keys(all) === CLASSIC.join(','), 'the registry is not changed');
}
