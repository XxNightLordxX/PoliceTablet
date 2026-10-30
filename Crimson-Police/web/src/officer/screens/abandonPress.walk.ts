// My options -> During a mission (step O10) against the browser mocks (node walk.mjs, a gate step): Abandon without
// the dialog still takes two presses, and distances read in feet and miles on the HUD fixture.

import '../../mocks/options.mock';
import { sampleHud } from '../../mocks/samples';
import { formatDistance } from '../../shared/format';
import { clientAction, request } from '../../shared/nui';
import type { OptionsView } from '../../types/options';
import { abandonPress, type AbandonPress } from './abandonPress';

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

// Presses of Abandon in a row (the screen keeps armed while the button reads "Click again to abandon").
function presses(confirm: boolean, n: number): AbandonPress[] {
    let armed = false;
    const out: AbandonPress[] = [];
    for (let i = 0; i < n; i++) {
        const next = abandonPress(confirm, armed);
        armed = next === 'arm';
        out.push(next);
    }
    return out;
}

async function steps(): Promise<void> {
    // the options: three rows of During a mission, shipped as today
    const opts = await request<OptionsView>('getOptions', {});
    const schema = Object.values(opts.data?.schema ?? []);
    const row = (key: string) => schema.find(d => d.key === key);
    ok(row('abandonConfirm')?.default === true, 'Abandon asks in a dialog by default, as before');
    ok(row('skipRecalcConfirm')?.default === false, 'Recalculate asks first by default, as before');
    ok(row('distanceUnits')?.default === 'metric' && row('distanceUnits')?.store === 'local', 'metres, on this PC');

    // Abandon: the dialog as before; without it, the first press only arms the button
    ok(presses(true, 1).join() === 'dialog', 'with the dialog: one press opens it');
    ok(presses(false, 1).join() === 'arm', 'without the dialog: one press abandons nothing');
    ok(presses(false, 2).join() === 'arm,abandon', 'without the dialog: the second press abandons');

    // every abandon takes two presses
    let sent = 0;
    for (const press of presses(false, 4)) if (press === 'abandon') sent += 1;
    ok(sent === 2, 'four presses abandon twice at most: every abandon takes two presses');

    // distances: metres as before, feet and miles when picked
    const off = sampleHud('offroute').route?.distance ?? 0;
    const target = sampleHud('test').target?.distance ?? 0;
    ok(formatDistance(off) === '1.5 km' && formatDistance(target) === '40 m', 'metric: the HUD reads as before');
    ok(formatDistance(off, 'imperial') === '0.9 mi', 'imperial: the route line of the HUD fixture in miles');
    ok(formatDistance(target, 'imperial') === '131 ft', 'imperial: under a tenth of a mile in feet');
    ok(formatDistance(12850, 'imperial') === '8.0 mi' && formatDistance(32000, 'imperial') === '20 mi', 'long ones');
    const saved = await clientAction<{ options?: Record<string, unknown> }>('setLocalOption', {
        key: 'distanceUnits',
        value: 'imperial',
    });
    ok(saved.ok && saved.data?.options?.distanceUnits === 'imperial', 'miles are kept on this PC');
    await clientAction('setLocalOption', { key: 'distanceUnits', value: 'metric' });
}
