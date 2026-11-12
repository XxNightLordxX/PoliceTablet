// Settings -> Features walked against the browser mocks (node walk.mjs, a gate step): each feature switch by section
// of play (NPC missions, Player vs police, Police teamwork, money, the server) with the setting it writes (a risky
// one asks first, a money one keeps its typed ENABLE). The Admin UI sidebar's groups: layouts/adminNav.walk.ts.

import '../../mocks/settings.mock';
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
    const set = await action('server:admin:setSetting', { path: 'RealPlayers.liveCrime.enabled', value: true });
    ok(set.ok, 'the switch saves through server:admin:setSetting');
    const again = await request<SettingsData>('admin:getSettings', {});
    const after = featureSections(again.data)[0];
    ok(after?.rows.find(r => r.f.key === 'live_crimes')?.on === true && after.on === 1, 'the feature shows on');
    await action('server:admin:resetSetting', { path: 'RealPlayers.liveCrime.enabled' });
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}
