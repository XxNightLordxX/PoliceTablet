// One design system for the four tablets against the browser mocks (node walk.mjs, a gate step): every screen of the

// One design system for the four tablets against the browser mocks (node walk.mjs, a gate step): every screen of the
// officer, supervisor, admin and criminal tablets has a head (title and one line of help) and every <Screen> uses
// it; the shared Table sorts, filters and pages; the shared Pager, ConfirmButton and ScreenStatus are the only ones;
// the spacing tokens and the criminal tablet's street theme; the criminal tablet built from the shared components.

import '../mocks/criminal.mock';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CriminalTablet } from '../criminal/CriminalTablet';
import crimCss from '../criminal/criminal.css?raw';
import { CRIM_SCREENS, normalizeCrimView } from '../criminal/model';
import { mockCrimReset } from '../mocks/criminal.mock';
import { mockLocale } from '../mocks/samples';
import { ADMIN_SCREENS, OFFICER_SCREENS, SUPERVISOR_SCREENS } from '../layouts/screens';
import baseCss from '../styles/base.css?raw';
import uiLocale from '../../../locales/parts/ui.json';
import kitLocale from '../../../locales/parts/admin_kit.json';
import type { CrimView } from '../types/criminal';
import { ConfirmButton, Pager, Screen, Table, filterRows, pageRows, sortRows, type TableColumn } from './components';
import { setLocale } from './i18n';
import { request } from './nui';
import { SCREEN_HEADS, TABBED_SCREENS } from './screenHeads';

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

// every screen source of the four tablets (the dev-only mocks gallery aside)
const SCREEN_CSS = import.meta.glob('../**/*.css', { query: '?raw', import: 'default', eager: true }) as Record<
    string,
    string
>;
const SOURCES = import.meta.glob('../**/*.tsx', { query: '?raw', import: 'default', eager: true }) as Record<
    string,
    string
>;

type Row = { id: number; name: string; points: number | null };
const ROWS: Row[] = [
    { id: 1, name: 'Mason Reed', points: 30 },
    { id: 2, name: 'ava Cole', points: null },
    { id: 3, name: 'Liam Ortiz', points: 120 },
    { id: 4, name: 'Zoe Hart', points: 8 },
];
const COLS: TableColumn<Row>[] = [
    { key: 'name', header: 'Name', sortable: true },
    { key: 'points', header: 'Points', numeric: true, sortable: true },
];

async function steps(): Promise<void> {
    setLocale(mockLocale);
    const L = mockLocale;
    const heads = SCREEN_HEADS as Record<string, { title: string; help: string }>;

    // every screen of every tablet has a head with its title and one short line of help
    const keys = [
        ...OFFICER_SCREENS.map(s => s.key),
        ...SUPERVISOR_SCREENS.map(s => s.key),
        ...ADMIN_SCREENS.map(s => s.key),
        ...CRIM_SCREENS.map(s => `crim_${s}`),
    ].filter(k => !TABBED_SCREENS.includes(k));
    ok(keys.length >= 30, `every tablet's screens listed (${keys.length})`);
    for (const k of keys) ok(heads[k], `${k}: has a head`);
    for (const [k, h] of Object.entries(heads)) {
        ok(typeof L[h.title] === 'string' && L[h.title].length > 0, `${k}: title in the locale`);
        const help = L[h.help];
        ok(typeof help === 'string' && help.length > 0 && help.length <= 120, `${k}: help is one short line`);
        ok(typeof help === 'string' && !help.includes('\n') && !help.includes('{'), `${k}: help has no variables`);
    }

    // every <Screen> of every tablet passes its head first, and only a known one
    let screens = 0;
    for (const [path, src] of Object.entries(SOURCES)) {
        if (path.includes('/mocks/') || path.endsWith('/components/Card.tsx')) continue;
        const all = src.match(/<Screen[\s>]/g)?.length ?? 0;
        const withHead = src.match(/<Screen\s+head=/g)?.length ?? 0;
        screens += all;
        ok(all === withHead, `${path}: every <Screen> has a head (${withHead} of ${all})`);
        for (const m of src.matchAll(/<Screen\s+head="(\w+)"/g)) ok(heads[m[1]], `${path}: head ${m[1]} is known`);
        // the per-tablet copies are gone: one Pager, one ScreenStatus, one two-click confirm
        ok(!src.includes('kit/Pager') && !src.includes('admin-kit-pager'), `${path}: the shared Pager`);
        ok(!src.includes('components/ScreenStatus') || path.endsWith('index.ts'), `${path}: the shared ScreenStatus`);
        ok(!/setTimeout\(\(\) => set\w+\(false\), 3000\)/.test(src), `${path}: two clicks through ConfirmButton`);
    }
    ok(screens >= 45, `the screens use <Screen> (${screens})`);

    // the header: the head's title and help, a title of its own wins, no head no header
    const html = (props: Record<string, unknown>) => renderToStaticMarkup(createElement(Screen, props, 'body'));
    const unit = html({ head: 'unit', subtitle: 'S' });
    ok(unit.includes(`>${L['ui.screen.unit']}</h2>`), 'head: the title');
    ok(unit.includes(`cp-screen__help">${L['ui.help.unit']}<`), 'head: the help line');
    ok(unit.indexOf('cp-screen__subtitle') < unit.indexOf('cp-screen__help'), 'head: help under the subtitle');
    ok(html({ head: 'profile', title: 'Mason' }).includes('>Mason</h2>'), 'head: an own title wins');
    ok(!html({}).includes('cp-screen__header'), 'no head, no title: no header');
    ok(html({ head: 'admin_audit' }).includes(`>${L['ui.nav.plain.admin_audit']}</h2>`), 'admin: the plain name');

    // the Table: sort (stable, empty last, numbers as numbers, case ignored), filter by every word, pages
    const names = (rows: Row[]) => rows.map(r => r.id).join();
    ok(names(sortRows(ROWS, COLS, null)) === '1,2,3,4', 'sort: none keeps the order');
    ok(names(sortRows(ROWS, COLS, { key: 'name', dir: 'asc' })) === '2,3,1,4', 'sort: names, case ignored');
    ok(names(sortRows(ROWS, COLS, { key: 'points', dir: 'asc' })) === '4,1,3,2', 'sort: numbers, empty last');
    ok(names(sortRows(ROWS, COLS, { key: 'points', dir: 'desc' })) === '3,1,4,2', 'sort: descending, empty last');
    const text = (r: Row) => r.name;
    ok(names(filterRows(ROWS, '  ', text)) === '1,2,3,4', 'filter: nothing typed keeps every row');
    ok(names(filterRows(ROWS, 'OR', text)) === '3', 'filter: case ignored');
    ok(names(filterRows(ROWS, 'a e', text)) === '1,2,4', 'filter: every word');
    const p = pageRows(ROWS, 2, 3);
    ok(names(p.rows) === '4' && p.page === 2 && p.pages === 2, 'pages: the second page');
    ok(pageRows(ROWS, 9, 3).page === 2 && pageRows([], 1, 3).pages === 1, 'pages: past the end shows the last');
    ok(pageRows(ROWS, 1, 0).rows.length === 4, 'pages: no page size shows every row');

    const table = (props: Record<string, unknown>) =>
        renderToStaticMarkup(createElement(Table<Row>, { columns: COLS, rows: ROWS, ...props } as never));
    const plain = table({});
    ok(plain.includes('cp-table__sort') && !plain.includes('aria-sort'), 'table: sortable headers, unsorted');
    ok(!plain.includes('cp-table-box') && !plain.includes('cp-pager'), 'table: no box without filter or pages');
    const sorted = table({ defaultSort: { key: 'points', dir: 'desc' } });
    ok(sorted.includes('aria-sort="descending"'), 'table: the sorted column says so');
    ok(sorted.indexOf('Liam Ortiz') < sorted.indexOf('Mason Reed'), 'table: rows drawn in the sort order');
    const box = table({ filter: true, pageSize: 2 });
    ok(box.includes('cp-table__filter') && box.includes('cp-pager'), 'table: the search box and the Pager');
    // the Pager's own lines, not the admin kit's
    const uiLines = uiLocale as Record<string, string>;
    const kitLines = kitLocale as Record<string, string>;
    ok(
        ['ui.pager.prev', 'ui.pager.next', 'ui.pager.of'].every(k => !!uiLines[k]),
        'the Pager: ui.pager.* lines',
    );
    ok(!Object.keys(kitLines).some(k => k.startsWith('ui.kit.page_')), 'no ui.kit.page_* lines left');
    // the screens with their own search box over a list search the way the Table filter does
    for (const path of ['../admin/screens/Leaderboards.tsx', '../admin/screens/Testing.tsx']) {
        ok((SOURCES[path] ?? '').includes('filterRows('), `${path}: the shared Table search`);
    }
    // a screen made of tabs is one TabbedScreen
    for (const path of [
        '../admin/screens/Money.tsx',
        '../admin/screens/Review.tsx',
        '../supervisor/screens/Department.tsx',
    ]) {
        const src = SOURCES[path] ?? '';
        ok(src.includes('<TabbedScreen') && !src.includes('<Tabs'), `${path}: a TabbedScreen`);
    }
    ok(box.includes('Mason Reed') && !box.includes('Liam Ortiz'), 'table: the first page only');
    ok(table({ rows: [] }).includes('cp-empty'), 'table: the empty state');
    ok(renderToStaticMarkup(createElement(Pager, { page: 1, pages: 1, onPage: () => {} })) === '', 'pager: 1 page');

    const confirm = renderToStaticMarkup(
        createElement(ConfirmButton, { label: 'Stop', confirmLabel: 'Sure?', onConfirm: () => {} }),
    );
    ok(
        confirm.includes('cp-btn--danger') && confirm.includes('Stop') && !confirm.includes('Sure?'),
        'confirm: armed later',
    );

    // tokens: the spacing scale and the street theme's colours
    for (const n of [1, 2, 3, 4, 5, 6, 8]) ok(baseCss.includes(`--cp-space-${n}: ${n * 4}px;`), `--cp-space-${n}`);
    ok(/\.cp-theme-street \{[^}]*--cp-primary: #c6f432;/.test(baseCss), 'street theme: its acid green primary');
    // every screen's own CSS spaces on the scale: a gap, padding or margin of 4, 8, 12, 16, 20, 24 or 32 px is its
    // --cp-space token (the values between the steps stay as each screen tuned them)
    const onScale =
        /^\s*(?:gap|row-gap|column-gap|padding(?:-[a-z-]+)?|margin(?:-[a-z-]+)?)\s*:[^;{}]*(?<![\w.-])(?:4|8|12|16|20|24|32)px\b/m;
    const offScale = Object.entries(SCREEN_CSS)
        .filter(([path, css]) => !path.includes('/styles/') && onScale.test(css))
        .map(([path]) => path);
    ok(Object.keys(SCREEN_CSS).length > 40, 'the screen CSS files are found');
    ok(offScale.length === 0, `screen CSS spaces with the --cp-space tokens (raw px in ${offScale.join(', ')})`);

    // the criminal tablet: the shared components in the street theme, none of its old copies
    mockCrimReset();
    const res = await request<CrimView>('crimtab:get', {});
    const view = res.ok ? normalizeCrimView(res.data) : null;
    ok(view, 'criminal: a view from the mocks');
    if (view) {
        for (const s of CRIM_SCREENS) {
            const out = renderToStaticMarkup(
                createElement(CriminalTablet, {
                    view,
                    screen: s,
                    onScreen: () => {},
                    onView: () => {},
                    onClose: () => {},
                }),
            );
            ok(out.includes('cp-theme-street'), `criminal ${s}: the street theme`);
            ok(out.includes(`data-head="crim_${s}"`) && out.includes(L[`crimtab.help.${s}`]), `criminal ${s}: head`);
            ok(out.includes('cp-card'), `criminal ${s}: shared cards`);
            ok(!/crim-(card|btn|table|badge|empty|job|role)\b/.test(out), `criminal ${s}: no own copies`);
        }
    }
    ok(!/\.crim-(card|btn|table|badge)\b/.test(crimCss), 'criminal.css: no own card, button, table or badge');
}
