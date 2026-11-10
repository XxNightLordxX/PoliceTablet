// The Admin UI layout against the browser mocks (node walk.mjs, a gate step): Home, then the screens by job (People,
// Missions, Real players, Money, Review, System) each with a description, the rare tools under More, the search that
// jumps to any screen or tab, officer, mission or setting (Ctrl+K), the Review screen and the breadcrumb.

import '../mocks/core.mock';
import { request } from '../shared/nui';
import { setLocale, t } from '../shared/i18n';
import { mockLocale } from '../mocks/samples';
import type { Session } from '../shared/types';
import type { AdminMissionsData } from '../types/builder_client';
import type { OfficerSearchData } from '../types/oversight';
import {
    ADMIN_GROUPS,
    ADMIN_GROUP_OF,
    ADMIN_JUMPS,
    ADMIN_RARE,
    FOUND_MAX,
    SETTINGS_SEARCH,
    adminCrumbs,
    adminFoldOf,
    adminGroupOf,
    adminTitleKey,
    globalResults,
    isSearchKey,
    wordsMatch,
} from './adminNav';
import { ADMIN_SCREENS } from './screens';
import { inSections } from './Sidebar';
import { REVIEW_TABS, reviewTabOf } from '../admin/screens/Review';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

async function steps(): Promise<void> {
    // the whole locale (the screens' tab names are outside the bundled ui.json fallback)
    setLocale(mockLocale);
    const res = await request<Session>('getSession', { ui: 'admin' });
    ok(res.ok, 'getSession answers');
    ok(res.data?.config?.adminUi && !('plainLayout' in res.data.config.adminUi), 'the session has no layout switch');

    const keys = ADMIN_SCREENS.map(s => s.key);
    // every screen but Home has a group, every group is one of the six, and every group holds a screen
    ok(
        keys.filter(k => k !== 'admin_home').every(k => ADMIN_GROUPS.includes(ADMIN_GROUP_OF[k])),
        'every screen but Home sits under a group',
    );
    ok(
        ADMIN_GROUPS.every(g => keys.some(k => ADMIN_GROUP_OF[k] === g)),
        'no group is empty',
    );
    // plain names and descriptions exist for every screen and group (no internal ids shown)
    ok(
        keys.every(k => t(adminTitleKey(k)) !== adminTitleKey(k)),
        'every screen has a plain name',
    );
    ok(
        ADMIN_GROUPS.every(g => t(`ui.nav.admin_hint.${g}`) !== `ui.nav.admin_hint.${g}`),
        'every group has a one-line description',
    );

    // on: Home on top, then the six groups in order, rare tools under More
    const sections = ADMIN_GROUPS.map(k => ({ key: k, label: k, hint: `hint ${k}` }));
    const listed = inSections(
        keys.map(k => ({ key: k, play: adminGroupOf(k) })),
        sections,
    );
    ok(listed[0].item.key === 'admin_home' && !listed[0].heading, 'on: Home first with no heading');
    ok(
        listed
            .filter(x => x.heading)
            .map(x => x.heading)
            .join(',') === ADMIN_GROUPS.join(','),
        'on: People, Missions, Real players, Money, Review, System in order',
    );
    ok(
        listed.filter(x => x.heading).every(x => x.hint === `hint ${x.heading}`),
        'on: a description under each heading',
    );
    ok(
        listed.filter(x => !x.heading).every(x => x.hint === undefined),
        'on: no description without a heading',
    );
    ok(
        ADMIN_RARE.every(k => adminFoldOf(k) === 'more'),
        'on: the rarely used tools fold under More',
    );
    ok(adminFoldOf('admin_money') === 'main', 'on: Money shows without opening More');
    ok(
        !inSections(
            keys.filter(k => k !== 'admin_rs').map(k => ({ key: k, play: adminGroupOf(k) })),
            sections,
        ).some(x => x.heading === 'players'),
        'on: a hidden screen leaves no empty group',
    );

    // the groups hold what the owner looks for there
    const of = (g: string) => keys.filter(k => ADMIN_GROUP_OF[k] === g).join(',');
    ok(
        of('people') ===
            'admin_officers,admin_restrictions,admin_departments,admin_permissions,admin_leaderboards,admin_seasons',
        'People: officers, restrictions, departments, permissions (and the boards)',
    );
    ok(
        of('missions') === 'admin_missions,admin_live,admin_markers,admin_testing',
        'Missions: missions, markers, tests',
    );
    ok(of('players') === 'admin_rs', 'Real players: the real suspects screen');
    ok(of('review') === 'admin_review,admin_audit', 'Review: the Review screen and the activity log');
    ok(of('system') === 'admin_settings,admin_system', 'System: settings and server health');
    ok(
        ADMIN_SCREENS.find(s => s.key === 'admin_rs')?.visible !== undefined,
        'Real players: hidden with its only screen while live crimes and volunteers are off',
    );
    ok(REVIEW_TABS.join(',') === 'queue,profiles,corrections', 'Review: one queue, Profiles and Corrections');
    ok(reviewTabOf({ tab: 'profiles' }) === 'profiles' && reviewTabOf({}) === 'queue', 'Review: a link picks a tab');
    ok(reviewTabOf({ tab: 'flagged' }) === 'queue', 'Review: the old flagged and disputes tabs are gone');
    ok(
        REVIEW_TABS.every(k => t(`admin.review.tab.${k}`) !== `admin.review.tab.${k}`),
        'Review: every tab has a name',
    );
    const badJumps = ADMIN_JUMPS.filter(j => !keys.includes(j.screen) || t(j.label) === j.label).map(j => j.label);
    ok(!badJumps.length, `every tab the search jumps to is on a real screen and has a name (${badJumps.join(', ')})`);

    // search: by plain name, old name or group, every word must match
    const screens = keys.map(k => ({
        key: k,
        words: [t(adminTitleKey(k)), t(`ui.screen.${k}`), t(`ui.nav.admin_group.${ADMIN_GROUP_OF[k]}`)],
    }));
    const jumps = ADMIN_JUMPS.map(j => ({
        jump: j,
        label: `${t(adminTitleKey(j.screen))} › ${t(j.label)}`,
        words: [t(j.label), t(adminTitleKey(j.screen))],
    }));
    const find = (text: string, extra: Partial<Parameters<typeof globalResults>[0]> = {}) =>
        globalResults({ screens, jumps, ...extra }, text);
    const screenHits = (text: string) =>
        find(text)
            .filter(r => r.kind === 'screens')
            .map(r => r.screen + (r.params ? `:${JSON.stringify(r.params)}` : ''));
    ok(find('').length === 0 && find('   ').length === 0, 'search: nothing typed, nothing listed');
    ok(screenHits('audit').join(',') === 'admin_audit', 'search: the old name finds the screen');
    ok(screenHits('activity LOG').join(',') === 'admin_audit', 'search: the plain name finds it, any case');
    ok(screenHits('zzz').length === 0, 'search: no match, no screen listed');
    ok(
        wordsMatch(['Mission Builder'], 'build miss') && !wordsMatch(['Mission'], 'build'),
        'search: every word must match',
    );
    const builder = find(t('admin.missions.tab.builder')).find(r => r.params?.tab === 'builder');
    ok(builder?.screen === 'admin_missions', 'search: a tab (Mission Builder) opens its screen on that tab');
    const disputes = find(t('admin.review.tab.disputes')).find(r => r.params?.show === 'dispute');
    ok(disputes?.screen === 'admin_review', 'search: Disputes opens the Review queue on its disputes');
    const noRs = globalResults({ screens: screens.filter(s => s.key !== 'admin_rs'), jumps }, t('rs.ui.volunteers'));
    ok(!noRs.some(r => r.screen === 'admin_rs'), "search: a hidden screen's tabs are not listed");
    ok(screenHits('a').length <= FOUND_MAX.screens, 'search: a short list of screens');

    // officers, missions and settings from the mocks
    const officers = await request<OfficerSearchData>('admin:searchOfficers', { query: 'a', filters: {}, page: 1 });
    const missions = await request<AdminMissionsData>('admin:getMissions', {});
    const m0 = missions.data?.missions?.[0];
    ok(officers.ok && (officers.data?.officers?.length ?? 0) > 0 && m0, 'the mocks have officers and missions');
    const o0 = officers.data?.officers?.[0];
    const withData = find(m0?.label ?? '', {
        officers: officers.data?.officers,
        missions: missions.data?.missions,
        settings: [{ path: 'Tablet.title', label: m0?.label ?? '' }],
    });
    const mHit = withData.find(r => r.kind === 'missions');
    ok(mHit?.screen === 'admin_missions' && mHit.params?.mission === m0?.id, 'search: a mission opens its drawer');
    const oHit = withData.find(r => r.kind === 'officers');
    ok(oHit?.screen === 'admin_officers' && oHit.params?.citizenid === o0?.citizenid, 'search: an officer opens');
    ok(withData.filter(r => r.kind === 'officers').length <= FOUND_MAX.officers, 'search: at most five officers');
    const sHit = withData.find(r => r.kind === 'settings' && r.key !== SETTINGS_SEARCH);
    ok(
        sHit?.screen === 'admin_settings' && sHit.params?.q === 'Tablet.title',
        'search: a setting opens Settings on it',
    );
    const last = withData[withData.length - 1];
    ok(last?.key === SETTINGS_SEARCH && last.params?.q === m0?.label, 'search: ends with Search settings for ...');
    const kinds = withData.map(r => r.kind);
    ok(
        kinds.join(',') === [...kinds].sort((a, b) => order(a) - order(b)).join(','),
        'search: screens, then officers, missions and settings',
    );
    const noOfficers = globalResults(
        { screens: screens.filter(s => s.key !== 'admin_officers'), jumps, officers: officers.data?.officers },
        'a',
    );
    ok(!noOfficers.some(r => r.kind === 'officers'), 'search: no Officers screen, no officers listed');

    // Ctrl+K (or Cmd+K) focuses the search
    ok(isSearchKey({ key: 'k', ctrlKey: true }) && isSearchKey({ key: 'K', metaKey: true }), 'Ctrl+K and Cmd+K');
    ok(!isSearchKey({ key: 'k' }) && !isSearchKey({ key: 'k', ctrlKey: true, altKey: true }), 'not K alone');

    // breadcrumb: Home > group > screen; none on Home itself
    ok(adminCrumbs('admin_money').group === 'money', 'breadcrumb: Money sits under Money');
    ok(adminCrumbs('admin_review').group === 'review', 'breadcrumb: Review sits under Review');
    ok(!adminCrumbs('admin_home').home, 'breadcrumb: none on Home');
}

function order(kind: string): number {
    return ['screens', 'officers', 'missions', 'settings'].indexOf(kind);
}
