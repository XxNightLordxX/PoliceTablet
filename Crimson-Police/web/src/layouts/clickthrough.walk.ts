// What the browser click-through (tools/clickthrough.mjs) found, against the browser mocks (node walk.mjs).

// What the browser click-through (tools/clickthrough.mjs) found, against the browser mocks (node walk.mjs).
// An officer with no badges and no options (Lua sends an empty list as {}) opens in Admin -> Officers without the
// error card; every officer the Running now lists name opens; the sidebar scrolls when its list is taller than the
// screen (the Admin UI's groups on a 900 px high screen). It sits in layouts/ so it runs after the builder walks: its
// render sets the locale, and those walks read the keys.

import { createElement } from 'react';
import { renderToString } from 'react-dom/server';
import '../mocks/index';
import { mockLocale } from '../mocks/samples';
import layoutsCss from '../styles/layouts.css?raw';
import { ErrorBoundary } from '../shared/components';
import { LocaleProvider } from '../shared/i18n';
import { request } from '../shared/nui';
import { OptionsProvider } from '../shared/options';
import { SessionContext } from '../shared/session';
import type { Session } from '../shared/types';
import type { OfficerDetail } from '../types/oversight';
import { OfficerTools } from '../admin/components/officers/OfficerTools';

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

// OfficerTools inside the providers the Admin UI gives it; an error inside shows the error card.
function render(session: Session, o: OfficerDetail): string {
    const ctx = {
        session,
        ui: 'admin' as const,
        close: () => undefined,
        switchUi: async () => false,
        refreshSession: async () => undefined,
        switching: false,
    };
    const tools = createElement(OfficerTools, { o, onChanged: () => undefined });
    const bounded = createElement(ErrorBoundary, { children: tools });
    const options = createElement(OptionsProvider, { session, ambient: null, children: bounded });
    const withSession = createElement(SessionContext.Provider, { value: ctx }, options);
    const tree = createElement(LocaleProvider, { locale: mockLocale, children: withSession });
    const quiet = console.error;
    console.error = () => undefined;
    try {
        return renderToString(tree);
    } finally {
        console.error = quiet;
    }
}

async function steps(): Promise<void> {
    const s = await request<Session>('getSession', { ui: 'admin' });
    ok(s.ok && s.data, 'the admin session');
    const session = s.data as Session;

    // the officer as Lua sends him with no badges: {} in place of []
    const res = await request<OfficerDetail>('admin:getOfficer', { citizenid: 'PLM33990' });
    ok(res.ok && res.data, 'admin:getOfficer answers Nina Park');
    const o = { ...(res.data as OfficerDetail), badges: {} as unknown as OfficerDetail['badges'] };
    const html = render(session, o);
    ok(!html.includes('cp-empty--error'), 'no badges ({} from Lua): the officer tools show, no error card');
    ok(html.includes('admin-otools__badges'), 'no badges: the badges card shows (empty)');

    // every officer the Running now lists name (runs and refusals) opens in Officers
    type Named = { citizenid?: string };
    const live = await request<{ runs?: { participants?: Named[] }[] }>('admin:getLiveRuns', {});
    const refused = await request<{ refusals?: Named[] }>('admin:getRefusals', {});
    const cids = new Set<string>();
    for (const r of live.data?.runs ?? []) for (const m of r.participants ?? []) if (m.citizenid) cids.add(m.citizenid);
    for (const r of refused.data?.refusals ?? []) if (r.citizenid) cids.add(r.citizenid);
    ok(cids.size >= 4, 'Running now names officers');
    for (const cid of cids) {
        const d = await request<OfficerDetail>('admin:getOfficer', { citizenid: cid });
        ok(d.ok, `Running now -> ${cid} opens in Officers`);
    }

    // the sidebar scrolls when its list is taller than the screen
    const rule = /\.cp-sidebar \{([^}]*)\}/.exec(layoutsCss)?.[1] ?? '';
    ok(/overflow-y:\s*auto/.test(rule) && /min-height:\s*0/.test(rule), 'the sidebar scrolls (overflow-y: auto)');
}
