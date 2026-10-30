// Admin UI -> Permissions -> Mission controls (step P4) against the browser mocks (node walk.mjs, a gate step): the
// card's body rendered off (nothing switched on, nothing changed) and on with changed values, and a Reset.

import '../../mocks/oversight.mock';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { mockLocale } from '../../mocks/samples';
import { setLocale } from '../../shared/i18n';
import { action, request } from '../../shared/nui';
import type { MissionControlState, MissionControlsView } from '../../types/oversight';
import { MasterOffBanner, MissionControlList } from './MissionControlsCard';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const noop = () => {};
function render(view: MissionControlsView): string {
    return renderToStaticMarkup(
        createElement(MissionControlList, {
            view,
            busy: false,
            onSwitch: noop,
            onSaveBounds: noop,
            onSaveOwn: noop,
            onReset: noop,
        }),
    );
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
        setLocale(null); // the other walks read the bundled ui texts only
    }
    return { passed, failures };
}

async function steps(): Promise<void> {
    setLocale(mockLocale);
    const res = await request<MissionControlsView>('admin:getMissionControls', {});
    ok(res.ok, 'admin:getMissionControls answers');
    if (!res.ok || !res.data) return;
    const view = res.data;

    // On, with values: the five server-wide controls, their switches on, the changed ones with who and a Reset
    const on = render(view);
    for (const name of ['Mission cooldowns', 'Abandon cooldown', 'No-repeat rule', 'Hourly mission cap', 'Daily cap'])
        ok(on.includes(name.replace('Daily cap', 'Daily mission cap')), `on: ${name} is listed`);
    ok(on.includes('tactical ×0.5'), 'on: the scaled cooldown reads per mission type (no session: the type key)');
    ok(on.includes('Now: 6') && on.includes('config.lua: 8'), 'on: the hourly cap now 6, config.lua 8');
    ok(on.includes('set by SUP00002 (supervisor)'), 'on: who changed it');
    ok((on.match(/>Reset</g) ?? []).length === 2, 'on: a Reset on each changed control');
    ok(on.includes('Server-wide') && on.includes('Outside the switch'), 'on: server-wide and outside the switch');
    ok(!on.includes('Departments ('), 'on: a server-wide control has no department rows');

    // Off: every admin switch off and nothing changed: the config.lua values, no Reset
    const off: MissionControlsView = {
        ...view,
        master: false,
        serverWide: view.serverWide.map((c): MissionControlState => ({
            ...c,
            on: false,
            active: false,
            value: c.configValue,
            saved: undefined,
            setBy: undefined,
        })),
        bounds: Object.fromEntries(Object.entries(view.bounds ?? {}).map(([k, b]) => [k, { ...b, on: false }])),
    };
    const offHtml = render(off);
    ok(!offHtml.includes('>Reset<') && offHtml.includes('the config.lua value'), 'off: config.lua values, no Reset');
    ok(!offHtml.includes('aria-checked="true"'), 'off: every admin switch off');
    ok(renderToStaticMarkup(createElement(MasterOffBanner)).includes('switch above is off'), 'off: the banner');
    ok(render({ ...view, serverWide: [], departments: [] }).includes('No Mission controls'), 'none registered');

    // A per-department control (the edge mock's shape): the departments button
    const sample = view.serverWide[1];
    const perDept: MissionControlsView = {
        ...view,
        serverWide: [],
        departments: view.departments.map(d => ({
            ...d,
            controls: [{ ...sample, key: 'tDept', serverWide: false, master: true, own: { min: 5 } }],
        })),
    };
    ok(render(perDept).includes('Departments (2)'), 'a per-department control lists its departments');

    // Reset: the change is gone on the next read
    const r = await action('server:admin:resetMissionControl', { key: 'hourlyCap', reason: 'walk', requestId: 'w1' });
    ok(r.ok, 'reset answers');
    const again = await request<MissionControlsView>('admin:getMissionControls', {});
    const cap = again.data?.serverWide.find(c => c.key === 'hourlyCap');
    ok(cap && cap.saved === undefined && cap.value === 8, 'after the reset: the hourly cap is back to 8');
}
