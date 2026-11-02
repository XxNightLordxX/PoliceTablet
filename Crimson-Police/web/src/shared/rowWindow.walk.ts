// Windowed lists (step OP3, Config.AdminUi.windowRows) against the browser mocks (node walk.mjs, a gate step): the
// window math, and a long scrolling Table drawing only the rows in view while the option is on (every row while off).

import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { mockLocale } from '../mocks/samples';
import { Table } from './components/Table';
import { setLocale } from './i18n';
import { WINDOW_MIN_ROWS, WINDOW_OVERSCAN, rowWindow } from './rowWindow';

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

function rowsOf(html: string): number {
    return (html.match(/<tr/g) ?? []).length;
}

function steps(): void {
    setLocale(mockLocale);
    // the math: off, short lists and unmeasured views draw every row with no spacers
    const all = rowWindow(800, 0, 400, 32, false);
    ok(all.start === 0 && all.end === 800 && all.padTop === 0 && all.padBottom === 0, 'off: every row');
    const short = rowWindow(WINDOW_MIN_ROWS, 500, 400, 32, true);
    ok(short.start === 0 && short.end === WINDOW_MIN_ROWS, 'a list of 100 rows or fewer: every row');
    ok(rowWindow(800, 0, 0, 32, true).end === 800, 'no view height yet: every row');
    // the top of the list: the rows in view and the overscan below
    const top = rowWindow(800, 0, 400, 32, true);
    ok(top.start === 0 && top.end === Math.ceil(400 / 32) + WINDOW_OVERSCAN, `top: rows 0-${top.end}`);
    ok(top.padTop === 0 && top.padBottom === (800 - top.end) * 32, 'top: the spacer below holds the rest');
    // scrolled to row 300: the overscan above too, and the spacers add up to the whole list
    const mid = rowWindow(800, 300 * 32, 400, 32, true);
    ok(mid.start === 300 - WINDOW_OVERSCAN, `scrolled: starts ${WINDOW_OVERSCAN} rows above the view (${mid.start})`);
    ok(mid.padTop + (mid.end - mid.start) * 32 + mid.padBottom === 800 * 32, 'scrolled: the list keeps its height');
    // past the end (the list got shorter): the last rows, never an empty window
    const end = rowWindow(800, 900 * 32, 400, 32, true);
    ok(end.end === 800 && end.start <= end.end && end.padBottom === 0, 'past the end: the last rows');

    // a Leaderboards-sized table: 800 officers in a 400 px scroll box
    const rows = Array.from({ length: 800 }, (_, i) => ({ id: i + 1, name: `Officer ${i + 1}` }));
    const columns = [{ key: 'name', header: 'Name' }];
    const html = (windowRows: boolean) =>
        renderToStaticMarkup(createElement(Table, { columns, rows, maxHeight: 400, dense: true, windowRows }));
    const off = rowsOf(html(false));
    const on = rowsOf(html(true));
    ok(off === 801, `windowRows off: the header and every row (${off})`);
    ok(on < 50, `windowRows on: the header, the rows in view and a spacer (${on}; 801 before OP3)`);
    ok(html(true).includes('Officer 1<') && !html(true).includes('Officer 400<'), 'on: the first rows, not row 400');
    const noScroll = rowsOf(renderToStaticMarkup(createElement(Table, { columns, rows, windowRows: true })));
    ok(noScroll === 801, 'a table without its own scroll box always draws every row');
}
