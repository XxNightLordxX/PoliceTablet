// Every screen of every tablet walked against the browser mocks (node walk.mjs, a gate step).

// Every screen of every tablet walked against the browser mocks (node walk.mjs, a gate step).
// Each UI's session (Officer, Supervisor, Admin) shows every screen of its registry, each screen renders inside the
// providers App.tsx gives it (the locale, the session, the options and the navigation) with its title text in the
// locale, and every request a screen's source sends has a browser mock that answers it. The criminal tablet renders
// each of its screens.

import { createElement, Suspense, type ComponentType } from 'react';
import { renderToString } from 'react-dom/server';
import '../mocks/index';
import { mockLocale } from '../mocks/samples';
// the admin powers Lua gives every admin (ADMIN_ONLY_LIST)
import permissionsLua from '../../../modules/access/permissions.lua?raw';
import { mockCrimReset } from '../mocks/criminal.mock';
import { CriminalTablet } from '../criminal/CriminalTablet';
import { normalizeCrimView } from '../criminal/model';
import { ErrorBoundary } from '../shared/components';
import { LocaleProvider } from '../shared/i18n';
import { NavigationContext, type ScreenKey } from '../shared/navigation';
import { listMocks, request } from '../shared/nui';
import { OptionsProvider } from '../shared/options';
import { SessionContext } from '../shared/session';
import type { Session, UiKind } from '../shared/types';
import type { CrimScreen, CrimView } from '../types/criminal';
import { ADMIN_SCREENS, OFFICER_SCREENS, SUPERVISOR_SCREENS, screensFor, type ScreenDef } from './screens';

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

// The source of every screen and the parts it uses, to read the requests they send.
const SOURCES = import.meta.glob(
    ['../officer/**/*.tsx', '../supervisor/**/*.tsx', '../admin/**/*.tsx', '../builder/**/*.tsx'],
    {
        query: '?raw',
        import: 'default',
        eager: true,
    },
) as Record<string, string>;

const REGISTRY: Record<UiKind, ScreenDef[]> = {
    officer: OFFICER_SCREENS,
    supervisor: SUPERVISOR_SCREENS,
    admin: ADMIN_SCREENS,
};

// One render of a screen as ScreenHost gives it; a screen that loads on first use renders after its load.
function render(session: Session, ui: UiKind, def: ScreenDef, available: ScreenKey[]): string {
    const nav = { screen: def.key, params: {}, navigate: () => undefined, available };
    const ctx = {
        session,
        ui,
        close: () => undefined,
        switchUi: async () => false,
        refreshSession: async () => undefined,
        switching: false,
    };
    const screen = createElement(Suspense, { fallback: createElement('i', { 'data-loading': '1' }) }, [
        createElement(def.component as ComponentType, { key: def.key }),
    ]);
    const bounded = createElement(ErrorBoundary, { resetKey: def.key, children: screen });
    const navigated = createElement(NavigationContext.Provider, { value: nav }, bounded);
    const options = createElement(OptionsProvider, { session, ambient: null, children: navigated });
    const withSession = createElement(SessionContext.Provider, { value: ctx }, options);
    const tree = createElement(LocaleProvider, { locale: mockLocale, children: withSession });
    return renderToString(tree);
}

const tick = () => new Promise(resolve => setTimeout(resolve, 5));
// still loading: the screen's own Suspense fallback, or a part inside it that loads on first use (<!--$!-->)
const loading = (html: string) => html.includes('data-loading') || html.includes('<!--$!-->');

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

async function renderScreen(session: Session, ui: UiKind, def: ScreenDef, available: ScreenKey[]): Promise<string> {
    let html = quiet(() => render(session, ui, def, available));
    for (let i = 0; i < 200 && loading(html); i += 1) {
        await tick();
        html = quiet(() => render(session, ui, def, available));
    }
    return html;
}

async function steps(): Promise<void> {
    const mocked = new Set(listMocks().request);
    for (const ui of ['officer', 'supervisor', 'admin'] as UiKind[]) {
        const res = await request<Session>('getSession', { ui });
        ok(res.ok && res.data, `${ui}: getSession answers`);
        let session = res.data as Session;
        if (ui === 'admin') {
            // the mock admin has every admin power the server gives an admin, so every screen and tab shows
            const lua = permissionsLua;
            const list = /ADMIN_ONLY_LIST = \{([\s\S]*?)\n\}/.exec(lua)?.[1] ?? '';
            const powers = [...list.matchAll(/^\s*'(\w+)'/gm)].map(m => m[1]);
            ok(powers.length > 20, `admin: the admin powers read from permissions.lua (${powers.length})`);
            for (const p of powers) ok(session.actions.includes(p), `admin: the mock admin has ${p}`);
            // Real suspects shows while live crimes or volunteers are on (Config.RealPlayers.staff.screen)
            const config = session.config as unknown as Record<string, Record<string, unknown> | undefined>;
            session = {
                ...session,
                config: { ...session.config, realSuspects: { ...(config.realSuspects ?? {}), screen: true } },
            } as Session;
        }
        const shown = screensFor(ui, session);
        const available = shown.map(s => s.key);
        for (const def of REGISTRY[ui]) {
            ok(available.includes(def.key), `${ui}: the mock session shows ${def.key}`);
        }
        for (const def of shown) {
            ok(
                typeof mockLocale[def.titleKey] === 'string',
                `${ui}/${def.key}: its title ${def.titleKey} is in the locale`,
            );
            let html = '';
            try {
                html = await renderScreen(session, ui, def, available);
            } catch (e) {
                failures.push(`${ui}/${def.key}: render threw ${e instanceof Error ? e.message : String(e)}`);
                continue;
            }
            ok(html.length > 0 && !loading(html), `${ui}/${def.key}: renders`);
            ok(!html.includes('cp-empty--error'), `${ui}/${def.key}: no error card`);
        }
    }

    // every request the screens send has a mock, so the browser preview walks through every screen
    const names = new Set<string>();
    for (const src of Object.values(SOURCES)) {
        for (const m of src.matchAll(/\brequest(?:<[^>]*>)?\(\s*'([^']+)'/g)) names.add(m[1]);
    }
    ok(names.size > 20, `the screens send requests (${names.size})`);
    for (const name of [...names].sort()) ok(mocked.has(name), `request ${name} has a browser mock`);

    // the criminal tablet: every screen renders from the mock view
    mockCrimReset();
    const view = await request<CrimView>('crimtab:get', {});
    ok(view.ok, 'criminal: crimtab:get answers');
    const crim = normalizeCrimView(view.data) as CrimView;
    for (const screen of ['home', 'jobs', 'active', 'history', 'rules'] as CrimScreen[]) {
        let html = '';
        try {
            const tablet = createElement(CriminalTablet, {
                view: crim,
                screen,
                onScreen: () => undefined,
                onView: () => undefined,
                onClose: () => undefined,
            });
            html = quiet(() => renderToString(createElement(LocaleProvider, { locale: mockLocale, children: tablet })));
        } catch (e) {
            failures.push(`criminal/${screen}: render threw ${e instanceof Error ? e.message : String(e)}`);
            continue;
        }
        ok(html.length > 0, `criminal/${screen}: renders`);
    }
}
