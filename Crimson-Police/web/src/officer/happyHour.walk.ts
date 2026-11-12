// Happy hour as the timed cooldown change (node walk.mjs, a gate step): the officer banner names the scale
// when it is not 0 (and keeps "no mission cooldowns" at 0), and the Mission controls value text shows the scale and
// the no-repeat tail.

import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { useValueText } from '../admin/components/MissionControlsCard';
import { mockLocale } from '../mocks/samples';
import { setLocale } from '../shared/i18n';
import { SessionContext, type SessionContextValue } from '../shared/session';
import type { HappyHourState, Session } from '../shared/types';
import { HappyHourBanner } from './components/HappyHourBanner';

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

function inSession(child: ReturnType<typeof createElement>): string {
    const value: SessionContextValue = {
        session: { config: { adminUi: {} } } as unknown as Session,
        ui: 'officer',
        close: () => undefined,
        switchUi: async () => false,
        refreshSession: async () => undefined,
        switching: false,
    };
    return renderToStaticMarkup(createElement(SessionContext.Provider, { value }, child));
}

function banner(scale: number): string {
    const state: HappyHourState = { endsAt: 0, left: 600, minutes: 10, scale, noRepeat: false, by: 'Sgt Doe' };
    return inSession(createElement(HappyHourBanner, { state }));
}

function ValueText({ v }: { v: Record<string, number> }) {
    return createElement('span', null, useValueText()('happyHour', v));
}

function steps(): void {
    setLocale(mockLocale);
    ok(banner(0).includes('no mission cooldowns'), 'scale 0: the banner says no mission cooldowns, as before');
    ok(banner(0.5).includes('×0.5'), 'scale 0.5: the banner names the scale');
    ok(!banner(0.5).includes('no mission cooldowns'), 'scale 0.5: it never says there are none');
    const plain = inSession(createElement(ValueText, { v: { minutes: 15, scale: 0, noRepeat: 0 } }));
    ok(plain.includes('15 min') && !plain.includes('×'), 'value text at scale 0: the minutes only');
    const scaled = inSession(createElement(ValueText, { v: { minutes: 15, scale: 0.5, noRepeat: 1 } }));
    ok(scaled.includes('×0.5') && scaled.includes('no-repeat off'), 'value text: the scale and the no-repeat tail');
}
