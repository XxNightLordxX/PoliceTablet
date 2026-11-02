// Officer screens tidy, part 2 (step H3) against the browser mocks (node walk.mjs, a gate step): Unit, Profile,
// Leaderboard and My options share the part 1 header (title, one line of help) and load states; the field training
// card counts the tasks ready to sign; the live case card says which step of three the case is on.

import '../../mocks/core.mock';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import boards from '../../../../locales/parts/boards.json';
import fieldTraining from '../../../../locales/parts/field_training.json';
import livecrime from '../../../../locales/parts/livecrime.json';
import options from '../../../../locales/parts/options.json';
import teams from '../../../../locales/parts/teams.json';
import ui from '../../../../locales/parts/ui.json';
import { readyToSign } from '../components/FieldTrainingCard';
import { LiveCaseCard, stepIndex } from '../components/LiveCaseCard';
import { ScreenStatus } from '../components/ScreenStatus';
import type { FtoTask, FtoView } from '../../types/fieldTraining';
import challengeSrc from './Challenge.tsx?raw';
import leaderboardSrc from './Leaderboard.tsx?raw';
import optionsSrc from './MyOptions.tsx?raw';
import profileSrc from './Profile.tsx?raw';
import unitSrc from './Unit.tsx?raw';
import { OFFICER_HEADS } from './screenHead';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const noop = () => {};
const locale = { ...boards, ...fieldTraining, ...livecrime, ...options, ...teams, ...ui } as Record<string, string>;

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        steps();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

function task(type: string, ready: boolean, signed = false): FtoTask {
    return {
        type,
        label: type,
        runs: 1,
        need: 1,
        ready,
        signed: signed ? { by: 'T', at: 0 } : null,
    } as unknown as FtoTask;
}

function steps(): void {
    // the four part 2 screens: heads in the locale, help one short line, shared heads and state lines
    const sources: [keyof typeof OFFICER_HEADS, string][] = [
        ['unit', unitSrc],
        ['profile', profileSrc],
        ['leaderboard', leaderboardSrc],
        ['options', optionsSrc],
    ];
    for (const [key, src] of sources) {
        const head = OFFICER_HEADS[key];
        ok(head, `${key}: has a head`);
        if (!head) continue;
        ok(typeof locale[head.title] === 'string' && locale[head.title].length > 0, `${key}: title in the locale`);
        const help = locale[head.help];
        ok(typeof help === 'string' && help.length > 0, `${key}: help in the locale`);
        ok(typeof help === 'string' && !help.includes('\n') && help.length <= 120, `${key}: help is one short line`);
        ok(src.includes(`OFFICER_HEADS.${key}.title`), `${key}: title from OFFICER_HEADS`);
        ok(src.includes(`OFFICER_HEADS.${key}.help`), `${key}: help from OFFICER_HEADS`);
        ok(src.includes('<ScreenStatus'), `${key}: ScreenStatus for its load states`);
        ok(!src.includes('<LoadingBlock') && !src.includes('<ErrorState'), `${key}: no own loading or error block`);
    }

    // Challenge (R1): the same head and load states; its contributors dialog keeps its own compact error line
    ok(challengeSrc.includes('OFFICER_HEADS.challenge.title'), 'challenge: title from OFFICER_HEADS');
    ok(challengeSrc.includes('OFFICER_HEADS.challenge.help'), 'challenge: help from OFFICER_HEADS');
    ok(challengeSrc.includes('<ScreenStatus') && !challengeSrc.includes('<LoadingBlock'), 'challenge: ScreenStatus');
    ok(typeof locale['ui.help.challenge'] === 'string' && locale['ui.help.challenge'].length <= 120, 'challenge: help');

    // the loading line keeps the screen's own text (Profile, Leaderboard)
    const loading = renderToStaticMarkup(
        createElement(ScreenStatus, { state: 'loading', onRetry: noop, loadingText: 'Loading the board' }),
    );
    ok(loading.includes('cp-loading-block') && loading.includes('Loading the board'), 'loading: own text shown');

    // field training: tasks ready and not signed, over every rookie
    const view = (tasks: FtoTask[]) => ({ tasks }) as unknown as FtoView;
    ok(readyToSign([]) === 0, 'training: no rookies, none ready');
    ok(readyToSign([view([task('a', true), task('b', false)]), view([task('c', true)])]) === 2, 'training: 2 ready');
    ok(readyToSign([view([task('a', true, true)])]) === 0, 'training: a signed task is not ready');
    ok(typeof locale['fto.ready_count'] === 'string' && locale['fto.ready_count'].includes('{n}'), 'fto.ready_count');

    // live case: the step index and the "Step n of 3" badge with the current step marked
    ok(stepIndex('respond') === 0 && stepIndex('secure') === 1 && stepIndex('detain') === 2, 'live: step index');
    ok(typeof locale['run.live.step_of'] === 'string', 'run.live.step_of in the locale');
    const card = renderToStaticMarkup(
        createElement(LiveCaseCard, { live: { suspects: 2, phase: 'secure', title: 'Robbery' } }),
    );
    ok(card.includes('aria-current="step"'), 'live: the current step is marked');
    ok((card.match(/aria-current/g) ?? []).length === 1, 'live: only one step is current');
    ok((card.match(/cp-badge /g) ?? []).length === 2, 'live: the LIVE badge and the step badge');
}
