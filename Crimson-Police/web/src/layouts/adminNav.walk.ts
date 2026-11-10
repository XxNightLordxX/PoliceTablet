// The Admin UI layout against the browser mocks (node walk.mjs, a gate step): plain names, six described groups,
// the rare tools under More, the screen search and the breadcrumb (the only layout since BK1).

import '../mocks/core.mock';
import { request } from '../shared/nui';
import { t } from '../shared/i18n';
import type { Session } from '../shared/types';
import {
    ADMIN_GROUPS,
    ADMIN_GROUP_OF,
    ADMIN_RARE,
    adminCrumbs,
    adminFoldOf,
    adminGroupOf,
    adminTitleKey,
    searchScreens,
} from './adminNav';
import { ADMIN_SCREENS } from './screens';
import { inSections } from './Sidebar';

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
    const res = await request<Session>('getSession', { ui: 'admin' });
    ok(res.ok, 'getSession answers');
    ok(res.data?.config?.adminUi && !('plainLayout' in res.data.config.adminUi), 'the session has no layout switch');

    const keys = ADMIN_SCREENS.map(s => s.key);
    // every screen but Home has a group, every group is one of the seven, and every group holds a screen
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
        'on: NPC missions, Player vs police, Police teamwork, Rewards, Permissions, Economy, System in order',
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
        ).some(x => x.heading === 'pvp'),
        'on: a hidden screen leaves no empty group',
    );

    // search: by plain name, old name or group, every word must match
    const items = keys.map(k => ({
        key: k,
        words: [t(adminTitleKey(k)), t(`ui.screen.${k}`), t(`ui.nav.admin_group.${ADMIN_GROUP_OF[k]}`)],
    }));
    ok(searchScreens(items, '').length === 0, 'search: nothing typed, nothing listed');
    ok(
        searchScreens(items, 'audit')
            .map(i => i.key)
            .join(',') === 'admin_audit',
        'search: the old name finds the screen',
    );
    ok(
        searchScreens(items, 'activity LOG')
            .map(i => i.key)
            .join(',') === 'admin_audit',
        'search: the plain name finds it, any case',
    );
    ok(searchScreens(items, 'teamwork').length === 4, 'search: a group name finds its screens');
    ok(searchScreens(items, 'zzz').length === 0, 'search: no match, nothing listed');

    // breadcrumb: Home > group > screen; none on Home itself
    ok(adminCrumbs('admin_money').group === 'economy', 'breadcrumb: Money sits under Economy');
    ok(!adminCrumbs('admin_home').home, 'breadcrumb: none on Home');
}
