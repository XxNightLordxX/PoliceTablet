// My usual twists (step O15) against the browser mocks (node walk.mjs, a gate step): the accept step starts with the
// officer's usual twists that the card offers, so a usual twist the type does not offer is never sent; with none
// picked the department's pre-ticked twists (step P15) stay the start, as before.

import '../../mocks/options.mock';
import '../../mocks/run_ui.mock';
import { request } from '../../shared/nui';
import type { TwistOffer } from '../../shared/types';
import type { OptionsView } from '../../types/options';
import type { MissionBoardData, TypeCard } from '../../types/run_ui';
import { tickedTwists } from './twistTicks';

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
    const opts = await request<OptionsView>('getOptions', {});
    const schema = Array.isArray(opts.data?.schema) ? opts.data.schema : [];
    const row = schema.find(d => d.key === 'usualTwists');
    ok(row && row.kind === 'list' && row.group === 'board', 'My options: a Mission Board row My usual twists');
    const values = (opts.data?.values ?? {}) as Record<string, unknown>;
    ok(Array.isArray(values.usualTwists) && values.usualTwists.length === 0, 'shipped: no usual twists');

    const res = await request<MissionBoardData>('getMissionTypes', {});
    const cards = Object.values(res.data?.cards ?? []) as TypeCard[];
    const patrol = cards.find(c => c.key === 'patrol');
    const training = cards.find(c => c.key === 'training');
    ok(patrol && training, 'the mock board has Patrol and Training');
    const offersOf = (c?: TypeCard) => (c?.twists ?? []) as TwistOffer[];
    ok(!offersOf(training).some(o => o.key === 'armored_hostiles'), 'Training does not offer Armored Hostiles');

    // no usual twists: as before (nothing, or what the department ticks)
    ok(tickedTwists(offersOf(patrol), []).length === 0, 'no usual twists, nothing pre-ticked: none');
    const deptTicked = offersOf(patrol).map(o => ({ ...o, ticked: o.key === 'radio_silence' }));
    ok(tickedTwists(deptTicked, []).join(',') === 'radio_silence', "...the department's pre-ticked twist stays");

    // Time Crunch as usual: pre-ticked on a Patrol accept
    ok(tickedTwists(offersOf(patrol), ['time_crunch']).join(',') === 'time_crunch', 'Time Crunch pre-ticked');
    // the officer's choice wins over the department's
    ok(tickedTwists(deptTicked, ['time_crunch']).join(',') === 'time_crunch', "...instead of the department's");

    // a usual twist the type does not offer is not sent; the order is the offered order
    const sent = tickedTwists(offersOf(training), ['armored_hostiles', 'radio_silence', 'time_crunch']);
    ok(!sent.includes('armored_hostiles'), 'Training: Armored Hostiles is not sent');
    ok(sent.join(',') === 'time_crunch,radio_silence', '...the offered ones, in the offered order');
    ok(
        tickedTwists(offersOf(patrol), ['armored_hostiles']).join(',') === 'armored_hostiles',
        'Patrol: Armored Hostiles pre-ticked',
    );
    // junk from a saved value never reaches the accept
    ok(tickedTwists(offersOf(patrol), ['gone_twist', 7]).length === 0, 'an unknown twist is not sent');
}
