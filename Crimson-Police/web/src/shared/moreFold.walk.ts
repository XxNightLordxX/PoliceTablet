// The More fold against the browser mocks (node walk.mjs, a gate step): the options sit under More, closed at first,
// open as the viewer last left them (a blocked storage starts folded), and an option that is set never hides.

// The More fold against the browser mocks (node walk.mjs, a gate step): the options sit under More, closed at first,
// open as the viewer last left them (a blocked storage starts folded), and an option that is set never hides.
// fold={false} (open, no button), the fold (closed, the count), forceOpen, the open state remembered per screen and a blocked storage; which Mission controls fold and
// that a set one never does.

import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { mockLocale } from '../mocks/samples';
import { ADVANCED_CONTROLS, isFolded } from '../supervisor/screens/MissionControls';
import type { MissionControlState } from '../types/oversight';
import { MORE_PREFIX, MoreFold, readMoreOpen, writeMoreOpen } from './components/MoreFold';
import { SessionContext, type SessionContextValue } from './session';
import { setLocale } from './i18n';
import type { Session } from './types';

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

const g = globalThis as unknown as { window?: unknown };

function withSession(foldAdvanced: boolean | undefined, screen: string, extra: Record<string, unknown> = {}): string {
    const session = { config: { adminUi: {}, foldAdvanced } } as unknown as Session;
    const value: SessionContextValue = {
        session,
        ui: 'admin',
        close: () => undefined,
        switchUi: async () => false,
        refreshSession: async () => undefined,
        switching: false,
    };
    return renderToStaticMarkup(
        createElement(
            SessionContext.Provider,
            { value },
            createElement(MoreFold, { screen, ...extra, children: createElement('p', { id: 'rare' }, 'rare option') }),
        ),
    );
}

function control(key: string, saved?: unknown): MissionControlState {
    return { key, saved } as unknown as MissionControlState;
}

function steps(): void {
    setLocale(mockLocale);
    const saved = g.window;
    // no window storage at all (blocked): reading is folded, writing does not throw
    g.window = undefined;
    ok(readMoreOpen('x') === false, 'blocked storage: starts folded');
    let threw = false;
    try {
        writeMoreOpen('x', true);
    } catch {
        threw = true;
    }
    ok(!threw, 'blocked storage: writing never throws');

    // fold={false}: the option shows open, no More button
    const off = withSession(true, 'desk_dialog', { fold: false });
    ok(
        off.includes('rare option') && !off.includes('cp-more'),
        'fold false: the option shows open with no More button',
    );
    ok(withSession(undefined, 'desk_dialog').includes('cp-more'), 'every UI folds (no switch)');

    // on: a More button, the option folded
    const on = withSession(true, 'desk_dialog');
    ok(on.includes('cp-more__toggle') && !on.includes('rare option'), 'on: the option sits under a closed More');
    ok(on.includes('aria-expanded="false"'), 'on: More says it is closed');
    ok(withSession(true, 'desk_dialog', { count: 3 }).includes('(3)'), 'on: More shows how many options it holds');
    ok(withSession(true, 'desk_dialog', { forceOpen: true }).includes('rare option'), 'forceOpen: never hidden');

    // remembered per screen
    const store: Record<string, string> = {};
    g.window = {
        localStorage: {
            getItem: (k: string) => (k in store ? store[k] : null),
            setItem: (k: string, v: string) => {
                store[k] = v;
            },
        },
    };
    writeMoreOpen('desk_dialog', true);
    ok(store[`${MORE_PREFIX}desk_dialog`] === '1', 'the open state is kept under the screen key');
    ok(withSession(true, 'desk_dialog').includes('rare option'), 'left open: the screen opens with More open');
    ok(!withSession(true, 'dept_dialog').includes('rare option'), 'another screen keeps its own state');
    writeMoreOpen('desk_dialog', false);
    ok(!withSession(true, 'desk_dialog').includes('rare option'), 'closed again: folded');
    g.window = saved;

    // Mission controls: which controls fold; a set one never does
    ok(isFolded(control('noRepeat')), 'noRepeat (rarely changed) folds');
    ok(!isFolded(control('noRepeat', true)), 'a set control stays open');
    ok(!isFolded(control('cooldownScale')) && !isFolded(control('happyHour')), 'the everyday controls stay open');
    ok(!ADVANCED_CONTROLS.has('types') && !ADVANCED_CONTROLS.has('dailyCap'), 'types and caps are everyday');
}
