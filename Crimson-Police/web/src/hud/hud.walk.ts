// The in-world screens against the browser mocks (node walk.mjs, a gate step): the mission HUD and the result card.

// The in-world screens against the browser mocks (node walk.mjs, a gate step): the mission HUD (with its contact
// card and, on a test run, the test controls) and the result card (with its debrief), each sample of
// src/mocks/samples.ts rendered inside the HUD column with the providers App.tsx gives them. Each renders without an
// error, shows its text, and shows no raw locale key (an unknown key renders as the key itself). The layout in a
// real browser (covered or overlapping buttons, the column inside a 1280x720 screen) is tools/clickthrough.mjs's
// "world" pass.

import { createElement, type ReactElement } from 'react';
import { renderToString } from 'react-dom/server';
import '../mocks/index';
import {
    buildSession,
    mockLocale,
    sampleHud,
    sampleResult,
    type SampleHudKind,
    type SampleResultKind,
} from '../mocks/samples';
import { LocaleProvider } from '../shared/i18n';
import { OptionsProvider } from '../shared/options';
import { SessionContext } from '../shared/session';
import { Hud } from './Hud';
import { HudColumn } from './HudColumn';
import { ResultScreen } from './ResultScreen';

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

export const HUD_KINDS: SampleHudKind[] = ['progress', 'offroute', 'test'];
export const RESULT_KINDS: SampleResultKind[] = ['completed', 'failed', 'test', 'flagged', 'live', 'live_open'];

// The locale's namespaces (the first part of every key): a word of the text that starts with one of them followed by
// a dot is a key that rendered as itself.
const NAMESPACES = new Set(Object.keys(mockLocale).map(k => k.split('.')[0]));
// The text a player sees or hears: the text between the tags and the labels a tag carries (aria-label, title,
// placeholder, alt), never a class name or another attribute.
export function rawKeys(html: string): string[] {
    const labels = [...html.matchAll(/\s(?:aria-label|title|placeholder|alt)="([^"]*)"/g)].map(m => m[1]);
    const text = [
        html
            .replace(/<style[\s\S]*?<\/style>/g, ' ')
            .replace(/<[^>]*>/g, ' ')
            .replace(/&[a-z]+;|&#\d+;/g, ' '),
        ...labels,
    ].join(' ');
    const out: string[] = [];
    for (const m of text.matchAll(/\b([a-z][a-z0-9_]*)\.[a-z0-9_]+(?:\.[a-z0-9_]+)*\b/g)) {
        if (NAMESPACES.has(m[1])) out.push(m[0]);
    }
    return out;
}

// React's server renderer warns about every layout effect (they run only in the game's browser): kept quiet here.
function quiet<T>(fn: () => T): T {
    const error = console.error;
    console.error = () => undefined;
    try {
        return fn();
    } finally {
        console.error = error;
    }
}

// One render inside the HUD column, as App.tsx gives it (the locale, the session and the options). The server
// renderer has no error boundary: a part that throws (it would show nothing in game) throws out of here.
function render(child: ReactElement): string {
    const session = buildSession('officer');
    const ctx = {
        session,
        ui: 'officer' as const,
        close: () => undefined,
        switchUi: async () => false,
        refreshSession: async () => undefined,
        switching: false,
    };
    const column = createElement(HudColumn, { scale: 1, children: child });
    const options = createElement(OptionsProvider, { session, ambient: null, children: column });
    const withSession = createElement(SessionContext.Provider, { value: ctx }, options);
    const tree = createElement(LocaleProvider, { locale: mockLocale, children: withSession });
    return quiet(() => renderToString(tree));
}

function check(what: string, child: () => ReactElement, needs: string[]): void {
    let html = '';
    try {
        html = render(child());
    } catch (e) {
        failures.push(`${what}: render threw ${e instanceof Error ? e.message : String(e)}`);
        return;
    }
    const text = html
        .replace(/<[^>]*>/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
    ok(text.length > 20, `${what}: it shows its text (${text.length} characters)`);
    for (const n of needs) ok(html.includes(n), `${what}: it shows ${n}`);
    const keys = rawKeys(html);
    ok(keys.length === 0, `${what}: no raw locale key (${keys.join(', ')})`);
}

function steps(): void {
    for (const kind of HUD_KINDS) {
        const hud = sampleHud(kind);
        check(`hud ${kind}`, () => createElement(Hud, { hud }), [hud.missionLabel]);
    }
    for (const kind of RESULT_KINDS) {
        const result = sampleResult(kind);
        check(`result ${kind}`, () => createElement(ResultScreen, { result, onDismiss: () => undefined }), []);
    }
    // the check itself: a key with no text is found
    ok(rawKeys('<p>hud.not_a_key</p>').length === 1, 'a raw key in the text is found');
    ok(rawKeys(`<p>${mockLocale['common.close'] ?? 'Close'}</p>`).length === 0, 'a locale text is not a raw key');
}
