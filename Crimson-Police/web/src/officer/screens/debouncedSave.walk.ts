// My options: a group's Reset clicked within the save delay of a change is not undone by that change's
// pending save (node walk.mjs, a gate step).

import { makeDebouncer } from './debouncedSave';

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

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function steps(): Promise<void> {
    const saved: string[] = [];
    const d = makeDebouncer<string>((key, value) => saved.push(`${key}=${value}`), 20);

    d.later('a', '1');
    d.later('a', '2');
    await sleep(60);
    ok(saved.join() === 'a=2', 'one save per key, the last value');

    // a change, then the group's Reset before the delay: the reset cancels the pending save
    saved.length = 0;
    d.later('a', 'changed');
    d.later('b', 'other group');
    d.cancel(['a']);
    await sleep(60);
    ok(saved.join() === 'b=other group', 'the reset key is not saved again; another key still is');

    // closing the screen saves what is pending at once
    saved.length = 0;
    d.later('c', '3');
    d.flush();
    ok(saved.join() === 'c=3', 'flush saves at once');
    await sleep(60);
    ok(saved.join() === 'c=3', 'and only once');
}
