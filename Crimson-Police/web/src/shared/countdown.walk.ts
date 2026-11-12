// HUD countdowns (docs/dev/LOOPS.md): useCountdown wakes once a second, just after each whole second, instead
// of polling every 200 ms (node walk.mjs, a gate step).

import { COUNTDOWN_SLACK_MS, countdownWaitMs } from './hooks';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

function steps(): void {
    ok(countdownWaitMs(0) === 1000 + COUNTDOWN_SLACK_MS, `start: the first step is at 1 s (${countdownWaitMs(0)})`);
    ok(
        countdownWaitMs(2500) === 500 + COUNTDOWN_SLACK_MS,
        `half a second in: wait the other half (${countdownWaitMs(2500)})`,
    );
    ok(countdownWaitMs(1999) === 1 + COUNTDOWN_SLACK_MS, `just before a second: a few ms (${countdownWaitMs(1999)})`);
    ok(countdownWaitMs(-50) === 1000 + COUNTDOWN_SLACK_MS, 'a clock that went back counts as the start');

    // a 10 s countdown with timers that fire up to 30 ms late: 10 wakes, each in a new second, the last at 0
    let now = 0;
    let wakes = 0;
    let left = 10;
    const seen = new Set<number>();
    while (left > 0 && wakes < 100) {
        now += countdownWaitMs(now) + (wakes % 3) * 15;
        wakes += 1;
        left = Math.max(0, 10 - Math.floor(now / 1000));
        seen.add(left);
    }
    ok(wakes === 10, `a 10 s countdown wakes 10 times (${wakes}; 50 with the 200 ms poll)`);
    ok(seen.size === 10, `every wake shows a new second (${seen.size})`);
    ok(now < 10100, `it reaches 0 within 0.1 s of the end (${now} ms)`);
}
