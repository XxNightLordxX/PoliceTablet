// Officer screens tidy, part 1 (step H2) against the browser mocks (node walk.mjs, a gate step): Home, Mission Board,
// Active Mission and Dispatch share one header (title, one line of help) and one set of loading, error, empty and
// stale lines.

import '../../mocks/core.mock';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import foundation from '../../../../locales/parts/foundation.json';
import missioncalls from '../../../../locales/parts/missioncalls.json';
import runUi from '../../../../locales/parts/run_ui.json';
import ui from '../../../../locales/parts/ui.json';
import { Screen } from '../../shared/components';
import { ScreenStatus } from '../components/ScreenStatus';
import activeSrc from './ActiveMission.tsx?raw';
import dispatchSrc from './Dispatch.tsx?raw';
import homeSrc from './Home.tsx?raw';
import boardSrc from './MissionBoard.tsx?raw';
import { OFFICER_HEADS, screenStateOf, type ScreenState } from './screenHead';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const noop = () => {};
const locale = { ...foundation, ...missioncalls, ...runUi, ...ui } as Record<string, string>;

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

function steps(): void {
    // every screen has a title and one line of help, both in the locale
    for (const [key, head] of Object.entries(OFFICER_HEADS)) {
        ok(typeof locale[head.title] === 'string' && locale[head.title].length > 0, `${key}: title in the locale`);
        const help = locale[head.help];
        ok(typeof help === 'string' && help.length > 0, `${key}: help in the locale`);
        ok(typeof help === 'string' && !help.includes('\n') && help.length <= 120, `${key}: help is one short line`);
    }
    for (const k of ['ui.state.empty_title', 'ui.state.empty_text', 'ui.state.stale']) {
        ok(typeof locale[k] === 'string' && locale[k].length > 0, `${k} in the locale`);
    }

    // the load state from data, loading and error
    const cases: [boolean, boolean, string | null, ScreenState][] = [
        [false, true, null, 'loading'],
        [false, true, 'err.x', 'loading'],
        [false, false, 'err.x', 'error'],
        [false, false, null, 'empty'],
        [true, false, null, 'ready'],
        [true, true, 'err.x', 'ready'],
        [true, false, 'err.x', 'stale'],
    ];
    for (const [hasData, loading, error, want] of cases) {
        ok(screenStateOf(hasData, loading, error) === want, `state ${hasData}/${loading}/${error} is ${want}`);
    }

    // the state lines render; ready renders nothing
    const html = (state: ScreenState) =>
        renderToStaticMarkup(createElement(ScreenStatus, { state, error: 'err.x', onRetry: noop }));
    ok(html('loading').includes('cp-loading-block'), 'loading: the spinner block');
    ok(html('error').includes('cp-empty--error'), 'error: the error block');
    ok(html('empty').includes('cp-empty') && html('empty').includes('cp-btn'), 'empty: a block with Retry');
    ok(html('stale').includes('cp-screen-stale'), 'stale: the stale line');
    ok(html('ready') === '', 'ready: nothing');

    // the header shows the help line under the subtitle
    const head = renderToStaticMarkup(
        createElement(Screen, { title: 'T', subtitle: 'S', help: 'H' }, createElement('span', null, 'body')),
    );
    ok(
        head.includes('cp-screen__help') && head.indexOf('cp-screen__subtitle') < head.indexOf('cp-screen__help'),
        'Screen: help line under the subtitle',
    );
    ok(
        !renderToStaticMarkup(createElement(Screen, { title: 'T' })).includes('cp-screen__help'),
        'Screen: no help, no line',
    );

    // the four screens use the shared heads and state lines, not their own
    const sources: [string, string][] = [
        ['home', homeSrc],
        ['board', boardSrc],
        ['active', activeSrc],
        ['dispatch', dispatchSrc],
    ];
    for (const [key, src] of sources) {
        ok(src.includes(`OFFICER_HEADS.${key}.title`), `${key}: title from OFFICER_HEADS`);
        // the literal key also counts (tests/run_ui_spec.lua finds the run_ui keys a screen uses by their text)
        const help = OFFICER_HEADS[key as keyof typeof OFFICER_HEADS].help;
        ok(src.includes(`OFFICER_HEADS.${key}.help`) || src.includes(`'${help}'`), `${key}: help from OFFICER_HEADS`);
        ok(src.includes('<ScreenStatus'), `${key}: ScreenStatus for its load states`);
        ok(!src.includes('<LoadingBlock') && !src.includes('<ErrorState'), `${key}: no own loading or error block`);
    }
}
