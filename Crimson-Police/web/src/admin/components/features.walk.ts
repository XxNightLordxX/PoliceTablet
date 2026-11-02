// Admin UI split by play walked against the browser mocks (node walk.mjs, a gate step): the sidebar lists

// Admin UI split by play walked against the browser mocks (node walk.mjs, a gate step): the sidebar lists
// the admin screens under NPC missions, Player vs police, Police teamwork, then money and the server, and Settings ->
// Features lists each feature switch by section with the setting it writes (a risky one asks first, a money one
// keeps its typed ENABLE).

import '../../mocks/settings.mock';
import { ADMIN_SCREENS, PLAY_SECTIONS } from '../../layouts/screens';
import { inSections } from '../../layouts/Sidebar';
import { action, request } from '../../shared/nui';
import type { SettingsData } from '../../types/settings';
import { featureSections, limitValue, toggleNeeds } from './features';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

async function steps(): Promise<void> {
    // the sidebar: every admin screen but Home has a section, and the list is ordered by section
    const noSection = ADMIN_SCREENS.filter(s => !s.play).map(s => s.key);
    ok(noSection.length === 1 && noSection[0] === 'admin_home', 'only Home sits above the sections');
    const sections = PLAY_SECTIONS.map(k => ({ key: k, label: k.toUpperCase() }));
    const listed = inSections(ADMIN_SCREENS, sections);
    ok(listed.length === ADMIN_SCREENS.length, 'every screen is still listed (the same keys and links)');
    ok(listed[0].item.key === 'admin_home' && !listed[0].heading, 'Home first, with no heading');
    ok(listed[1].heading === 'NPC', 'then the NPC missions heading');
    ok(listed[1].item.key === 'admin_missions', 'over Missions');
    ok(listed.find(l => l.item.key === 'admin_rs')?.heading === 'PVP', 'Real suspects heads Player vs police');
    const team = listed.filter(l => l.item.play === 'team').map(l => l.item.key);
    ok(team.includes('admin_officers') && team.includes('admin_leaderboards'), 'officers and boards are teamwork');
    ok(listed.filter(l => l.heading).length === PLAY_SECTIONS.length, 'one heading per section');
    const flat = inSections(ADMIN_SCREENS, undefined);
    ok(
        flat.every((l, i) => l.item.key === ADMIN_SCREENS[i].key && !l.heading),
        'off: the order as before',
    );

    // Settings -> Features
    const res = await request<SettingsData>('admin:getSettings', {});
    const secs = featureSections(res.data);
    ok(secs.length === 1 && secs[0].play === 'pvp', 'a section shows only while it has a feature with its setting');
    const rows = secs[0]?.rows ?? [];
    ok(rows.length === 2, 'a feature whose setting is missing is left out');
    const live = rows.find(r => r.f.key === 'live_crimes');
    const cash = rows.find(r => r.f.key === 'live_cash');
    ok(live && live.on === false && secs[0].on === 0, 'live crimes ship off');
    ok(live && toggleNeeds(live, true) === 'risky', 'turning live crimes on asks first');
    ok(cash && toggleNeeds(cash, true) === 'money', 'cash for live cases keeps the typed ENABLE');
    ok(cash && toggleNeeds(cash, false) === null, 'turning money off saves at once');
    // each feature links its limits; a limit the data does not have is left out
    ok(
        live?.limits.length === 1 && live.limits[0].path === 'Limits.maxUnitSize' && limitValue(live.limits[0]) === '6',
        'live crimes link the unit size with its value',
    );
    ok(cash?.limits.length === 0, 'a feature with no limits links none');
    ok(limitValue({ ...live!.limits[0], value: { a: 1, b: 2 } }) === '{2}', 'a map limit shows its size');

    // the toggle writes the same setting as the list
    const set = await action('server:admin:setSetting', { path: 'LiveCrime.enabled', value: true });
    ok(set.ok, 'the switch saves through server:admin:setSetting');
    const again = await request<SettingsData>('admin:getSettings', {});
    const after = featureSections(again.data)[0];
    ok(after?.rows.find(r => r.f.key === 'live_crimes')?.on === true && after.on === 1, 'the feature shows on');
    await action('server:admin:resetSetting', { path: 'LiveCrime.enabled' });
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
