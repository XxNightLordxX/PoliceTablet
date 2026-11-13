// The guided tours (Config.Training) against the browser mocks (node walk.mjs, a gate step): every step's

// The guided tours (Config.Training) against the browser mocks (node walk.mjs, a gate step): every step's
// element exists in the sources (a data-tour id renamed or dropped in a UI change fails here), every step has its
// text, every screen a step opens is a screen (and tab) of its tablet, the versions match modules/access/training.lua,
// a tour shows once and a new version shows only its new steps, and the card always stays inside the window. The
// tips of the first mission run: each waits for its part of the HUD, shows once in order, and is saved at the result.

import '../../mocks/index';
import trainingLua from '../../../../modules/access/training.lua?raw';
import trainingText from '../../../../locales/parts/training.json';
import { CRIM_SCREENS } from '../../criminal/model';
import { ADMIN_SCREENS, OFFICER_SCREENS, SUPERVISOR_SCREENS } from '../../layouts/screens';
import { DEPT_TABS } from '../../layouts/supDepartment';
import { action, request } from '../nui';
import { SCREEN_HEADS } from '../screenHeads';
import { placeCard } from './place';
import { tourArrow, tourCovered } from './TourHost';
import {
    askTour,
    autoTourFor,
    beginRun,
    endRun,
    moveRun,
    normalizeTraining,
    finishHints,
    hintShown,
    setTrainingView,
    takeAsked,
    takeHintsAgain,
    tourState,
    type TrainingView,
} from './store';
import { hintCond, hintsFinished, hintsToShow, nextHint } from './runHints';
import { tourStatus } from './TourButtons';
import {
    TOURS,
    TOUR_IDS,
    stepBodyKey,
    stepTitleKey,
    stepsToShow,
    tourVersion,
    toursOf,
    type TourCtx,
    type TourDef,
} from './tours';

const failures: string[] = [];
let passed = 0;
function ok(cond: unknown, what: string): void {
    if (cond) passed += 1;
    else failures.push(what);
}

const SOURCES = import.meta.glob('../../**/*.tsx', { query: '?raw', import: 'default', eager: true }) as Record<
    string,
    string
>;
const TEXT = trainingText as Record<string, string>;

export async function walk(): Promise<{ passed: number; failures: string[] }> {
    try {
        await steps();
        dialogChecks();
    } catch (e) {
        failures.push(`stopped: ${e instanceof Error ? e.message : String(e)}`);
    }
    return { passed, failures };
}

const SCREENS_OF: Record<string, string[]> = {
    officer: OFFICER_SCREENS.map(s => s.key),
    supervisor: SUPERVISOR_SCREENS.map(s => s.key),
    admin: ADMIN_SCREENS.map(s => s.key),
    criminal: [],
    hud: [],
};

// The data-tour ids written out in the sources, and the generated ones: nav-<screen>, crim-nav-<screen>,
// screen-<head>.
function targetsKnown(): { fixed: Set<string>; generated: Record<string, boolean> } {
    const fixed = new Set<string>();
    const all = Object.values(SOURCES).join('\n');
    for (const m of all.matchAll(/data-tour="([\w-]+)"/g)) fixed.add(m[1]);
    return {
        fixed,
        generated: {
            nav: all.includes('data-tour={`nav-${it.key}`}'),
            crimNav: all.includes('data-tour={`crim-nav-${s}`}'),
            screen: all.includes('data-tour={head ? `screen-${head}` : undefined}'),
        },
    };
}

function targetExists(tour: TourDef, target: string, known: ReturnType<typeof targetsKnown>): boolean {
    if (known.fixed.has(target)) return true;
    const all = Object.values(SOURCES).join('\n');
    if (target.startsWith('nav-'))
        return known.generated.nav && SCREENS_OF[tour.tablet].includes(target.slice('nav-'.length));
    if (target.startsWith('crim-nav-'))
        return known.generated.crimNav && (CRIM_SCREENS as string[]).includes(target.slice('crim-nav-'.length));
    if (target.startsWith('screen-')) {
        const head = target.slice('screen-'.length);
        if (!known.generated.screen || !(head in SCREEN_HEADS)) return false;
        // the criminal tablet's screens take their head from the screen shown (head={`crim_${screen}`})
        if (head.startsWith('crim_')) return all.includes('head={`crim_${screen}`}');
        return all.includes(`head="${head}"`);
    }
    return false;
}

const FULL_CTX: TourCtx = {
    session: null,
    screens: [...SCREENS_OF.officer, ...SCREENS_OF.supervisor, ...SCREENS_OF.admin],
    deptTabs: [...DEPT_TABS],
    checklist: true,
};

async function steps(): Promise<void> {
    // ---- EVERY TOUR, EVERY STEP --------------------------------------------
    ok(TOUR_IDS.join(',') === 'officer,supervisor,admin,criminal,run', 'four tablet tours and the run tips');
    const known = targetsKnown();
    ok(known.generated.nav && known.generated.crimNav && known.generated.screen, 'the generated data-tour ids exist');
    ok(known.fixed.has('tour-help'), "every tablet's '?' button carries tour-help");
    for (const id of TOUR_IDS) {
        const tour = TOURS[id];
        ok(toursOf(tour.tablet).includes(id), `${id}: its tablet offers it`);
        ok(tour.steps.length >= (tour.tablet === 'hud' ? 3 : 5), `${id}: a real tour (${tour.steps.length} steps)`);
        // the run tips have no focus: no screen, no click, and each waits for its part of the HUD
        for (const s of tour.steps)
            ok(
                tour.tablet === 'hud' ? !!s.when && !!s.target && !s.screen && !s.crim && !s.waitFor : !s.when,
                `${id}.${s.id}: ${tour.tablet === 'hud' ? 'a run tip waits for its part of the HUD' : 'no run tip'}`,
            );
        const seen = new Set<string>();
        for (const s of tour.steps) {
            ok(!seen.has(s.id), `${id}.${s.id}: one step id once`);
            seen.add(s.id);
            ok(TEXT[stepTitleKey(id, s)] && TEXT[stepBodyKey(id, s)], `${id}.${s.id}: its title and text`);
            if (s.target) ok(targetExists(tour, s.target, known), `${id}.${s.id}: its element ${s.target} exists`);
            if (s.waitFor) ok(!!s.target, `${id}.${s.id}: waits for a click on an element`);
            if (s.screen) {
                ok(SCREENS_OF[tour.tablet].includes(s.screen.key), `${id}.${s.id}: ${s.screen.key} is its screen`);
                const p = s.screen.params ?? {};
                if (p.deptTab) ok((DEPT_TABS as string[]).includes(String(p.deptTab)), `${id}.${s.id}: dept tab`);
                if (s.screen.key === 'admin_settings' && p.tab)
                    ok(['presets', 'features', 'tours'].includes(String(p.tab)), `${id}.${s.id}: Settings tab`);
            }
            if (s.crim) ok((CRIM_SCREENS as string[]).includes(s.crim), `${id}.${s.id}: a criminal tablet screen`);
            ok(!s.crim || tour.tablet === 'criminal', `${id}.${s.id}: only the criminal tablet opens its screens`);
        }
        ok(stepsToShow(tour, 0, true, FULL_CTX).length === tour.steps.length, `${id}: every step with every screen`);
    }
    for (const k of ['tour.ui.step', 'tour.ui.skip', 'tour.ui.never', 'tour.ui.back', 'tour.ui.next', 'tour.ui.done'])
        ok(TEXT[k], `${k}: its text`);
    for (const id of TOUR_IDS) ok(TEXT[`tour.name.${id}`], `tour.name.${id}: its name`);

    // ---- THE VERSIONS MATCH THE SERVER'S LIST ------------------------------
    const block = /Tr\.TOURS = \{([^}]*)\}/.exec(trainingLua)?.[1] ?? '';
    const lua: Record<string, number> = {};
    for (const m of block.matchAll(/(\w+) = (\d+)/g)) lua[m[1]] = Number(m[2]);
    ok(Object.keys(lua).sort().join(',') === [...TOUR_IDS].sort().join(','), `the server knows every tour`);
    for (const id of TOUR_IDS) ok(lua[id] === tourVersion(TOURS[id]), `${id}: version ${lua[id]} on both sides`);

    // ---- A STEP A PLAYER MAY NOT SEE IS LEFT OUT ---------------------------
    const officer = TOURS.officer;
    const noDispatch = stepsToShow(officer, 0, true, {
        ...FULL_CTX,
        screens: SCREENS_OF.officer.filter(k => k !== 'dispatch'),
    });
    ok(
        !noDispatch.some(s => s.id === 'dispatch') && noDispatch.length === officer.steps.length - 1,
        'no Dispatch step',
    );
    const fewTabs = stepsToShow(TOURS.supervisor, 0, true, { ...FULL_CTX, deptTabs: ['officers'] });
    ok(!fewTabs.some(s => s.id === 'controls') && fewTabs.some(s => s.id === 'today'), 'only the tabs he may see');
    const noList = stepsToShow(TOURS.admin, 0, true, { ...FULL_CTX, checklist: false });
    ok(!noList.some(s => s.id === 'checklist'), 'setupChecklist off: no checklist step');

    // ---- SHOWS ONCE; a new version shows only its new steps ----------------
    const view = (seen: TrainingView['seen'], extra: Partial<TrainingView> = {}): TrainingView => ({
        enabled: true,
        autoStart: { officer: true, supervisor: true, admin: true, criminal: true },
        allowSkip: true,
        seen,
        ...extra,
    });
    ok(autoTourFor('officer', view({})) === 'officer', 'first open: the Officer tour starts');
    ok(autoTourFor('officer', view({ officer: tourVersion(officer) })) === null, 'finished: it does not start again');
    ok(autoTourFor('officer', view({}, { enabled: false })) === null, 'Config.Training.enabled = false: none');
    ok(autoTourFor('officer', view({}, { autoStart: { officer: false } })) === null, 'autoStart.officer = false');
    ok(autoTourFor('admin', view({}, { setupPending: true })) === null, 'the First-start setup first');
    ok(autoTourFor('admin', view({})) === 'admin' && autoTourFor('criminal', view({})) === 'criminal', 'each tablet');
    const v2: TourDef = { ...officer, steps: [...officer.steps, { id: 'later', target: 'tour-help', since: 2 }] };
    ok(tourVersion(v2) === 2, 'a step with since 2 makes version 2');
    const fresh = stepsToShow(v2, 1, false, FULL_CTX);
    ok(fresh.length === 1 && fresh[0].id === 'later', 'a player who finished version 1 sees only the new step');
    ok(stepsToShow(v2, 0, false, FULL_CTX).length === v2.steps.length, 'a new player sees every step');
    ok(stepsToShow(v2, 1, true, FULL_CTX).length === v2.steps.length, 'a replay shows every step');
    ok(tourStatus('officer', {}) === 'todo' && tourStatus('officer', { officer: 1 }) === 'done', 'Tours: the state');

    // ---- THE RUN, THE SAVE AND AN ASKED TOUR -------------------------------
    const saved: unknown[] = [];
    const real = await request<TrainingView>('training:get', {});
    const mockView = normalizeTraining(real.data);
    ok(mockView?.enabled && autoTourFor('officer', mockView) === null, 'the mocks start no tour by themselves');
    setTrainingView(view({}));
    beginRun('officer', ['welcome', 'status', 'board']);
    moveRun(1);
    moveRun(5);
    ok(tourState().run?.index === 2, 'Next stops at the last step');
    moveRun(-9);
    ok(tourState().run?.index === 0, 'Back stops at the first');
    endRun(false);
    ok(tourState().run === null && !tourState().view?.seen.officer, 'Skip or Escape: ended, not saved');
    beginRun('officer', ['welcome']);
    endRun(true);
    ok(tourState().view?.seen.officer === tourVersion(officer), 'Done: saved with its version');
    const done = await action<{ seen: Record<string, number> }>('server:training:done', {
        tour: 'officer',
        version: 1,
    });
    saved.push(done);
    ok(done.ok && done.data?.seen.officer === 1, 'server:training:done answers the saved tours');
    askTour('admin');
    ok(takeAsked('officer') === null && tourState().asked?.tour === 'admin', 'an asked tour waits for its tablet');
    ok(takeAsked('admin') === 'admin' && tourState().asked === null, 'and runs there once');
    askTour('criminal');
    ok(takeAsked('criminal', Date.now() + 11000) === null, 'an asked tour older than 10 s is dropped');
    setTrainingView(view({}, { enabled: false }));
    askTour('officer');
    ok(tourState().asked === null, 'tours off: nothing is asked');
    setTrainingView(null);

    // ---- THE TIPS OF THE FIRST MISSION RUN ---------------------------------
    for (const target of ['hud', 'hud-objectives', 'hud-route', 'result-card'])
        ok(known.fixed.has(target), `the run tips point at ${target}`);
    ok(TEXT['tour.ui.hint_auto'] && TEXT['tour.ui.state.queued'] && TEXT['tour.ui.run_next'], 'the run tips: texts');
    const hud = {
        runId: 'r1',
        phase: 'route',
        objectives: [],
        route: { status: 'on', distance: 300 },
    } as unknown as Parameters<typeof hintCond>[0];
    const first = view({});
    const tips = hintsToShow(first, false);
    ok(tips.map(s => s.id).join(',') === 'hud,objectives,gps,result', 'a new officer gets every tip');
    ok(hintsToShow(view({ run: tourVersion(TOURS.run) }), false).length === 0, 'finished: no tip again');
    ok(hintsToShow(view({ run: tourVersion(TOURS.run) }), true).length === tips.length, 'asked again: every tip');
    ok(hintsToShow(view({}, { autoStart: { run: false } }), false).length === 0, 'autoStart.run = false: none');
    ok(hintsToShow(view({}, { autoStart: { run: false } }), true).length === tips.length, 'but asked for: shown');
    ok(hintsToShow(view({}, { enabled: false }), true).length === 0 && hintsToShow(null, false).length === 0, 'off');
    const shown = new Set<string>();
    ok(nextHint(tips, shown, hintCond(null, false)) === null, 'no HUD on screen (the tablet over it): no tip');
    ok(nextHint(tips, shown, hintCond(hud, false))?.id === 'hud', 'the HUD shows: its tip first');
    shown.add('hud');
    ok(nextHint(tips, shown, hintCond(hud, false))?.id === 'gps', 'no objectives yet: the GPS tip next');
    shown.add('gps');
    ok(nextHint(tips, shown, hintCond(hud, false)) === null, 'then it waits for the objectives');
    const working = { ...hud, phase: 'objectives', route: null, objectives: [{ label: 'Go', done: false }] };
    ok(nextHint(tips, shown, hintCond(working as typeof hud, false))?.id === 'objectives', 'the objectives tip');
    ok(!hintCond({ ...working, target: null } as typeof hud, false).gps, 'no route and no pointer: no GPS line');
    ok(hintCond({ ...working, target: { label: 'x', distance: 5 } } as typeof hud, false).gps, 'the pointer is GPS');
    shown.add('objectives');
    ok(!hintsFinished(tips, shown), 'not finished before the result card');
    ok(nextHint(tips, shown, hintCond(null, true))?.id === 'result', 'the result card: its tip');
    ok(hintsFinished(tips, new Set(['hud', 'result'])), 'finished at the result tip, a missed tip not waited for');
    ok(!hintsFinished([], shown), 'nothing to show: nothing to save');
    const later: TourDef = {
        ...TOURS.run,
        steps: [...TOURS.run.steps, { id: 'x', target: 'hud', when: 'hud', since: 2 }],
    };
    ok(
        stepsToShow(later, 1, false, FULL_CTX)
            .map(s => s.id)
            .join() === 'x',
        'a new tip version: only the new tip',
    );
    setTrainingView(first);
    askTour('run');
    ok(tourState().hintsAgain && tourState().asked === null, 'Tours -> run: shown on the next run, no tablet asked');
    ok(takeHintsAgain() && tourState().hints.again && !tourState().hintsAgain, 'the next HUD takes it');
    hintShown('hud');
    hintShown('hud');
    ok(tourState().hints.shown.join() === 'hud', 'a tip counts once');
    finishHints();
    ok(tourState().view?.seen.run === tourVersion(TOURS.run), 'finished: saved with its version');
    ok(!tourState().hints.again && tourState().hints.shown.length === 0, 'and reset');
    ok(tourStatus('run', tourState().view?.seen) === 'done', 'Tours: the run tips finished');
    setTrainingView(null);

    // ---- THE CARD STAYS INSIDE THE WINDOW, AT ANY SIZE ---------------------
    const card = { width: 340, height: 180 };
    for (const win of [
        { width: 1920, height: 1080 },
        { width: 1280, height: 720 },
        { width: 800, height: 600 },
    ]) {
        for (const target of [
            null,
            { left: 10, top: 10, width: 40, height: 30 },
            { left: win.width - 50, top: win.height - 40, width: 40, height: 30 },
            { left: 0, top: 0, width: win.width, height: win.height },
        ]) {
            const at = placeCard(target, card, win);
            ok(
                at.left >= 0 && at.top >= 0 && at.left + card.width <= win.width && at.top + card.height <= win.height,
                `the card fits ${win.width}x${win.height} (${target ? target.left : 'none'})`,
            );
        }
    }
    const below = placeCard({ left: 100, top: 100, width: 60, height: 30 }, card, { width: 1280, height: 720 });
    ok(below.side === 'below' && below.top > 130, 'under a small element near the top');
}

// a dialog opened while a tour runs: the tour steps aside (its card would cover the dialog's buttons), unless the
// step points into that dialog
function dialogChecks(): void {
    const inside = { id: 'inside' };
    const outside = { id: 'outside' };
    const dialog = { contains: (n: unknown) => n === inside };
    ok(tourCovered(null, outside) === false, 'no dialog open: the tour shows');
    ok(tourCovered(dialog, outside) === true, 'a dialog open, the step points elsewhere: the tour steps aside');
    ok(tourCovered(dialog, null) === true, 'a dialog open, a step with no element: the tour steps aside');
    ok(tourCovered(dialog, inside) === false, 'the step points into the open dialog: the tour shows');
    // R7: while the tour steps aside the arrows are the dialog's: the hidden tour never moves
    ok(
        typeof tourArrow === 'function' && /tourArrow\(e\.key, covered\)/.test(SOURCES['./TourHost.tsx'] ?? ''),
        'the arrow keys go through tourArrow with covered',
    );
    if (typeof tourArrow === 'function') {
        ok(tourArrow('ArrowRight', false) === 1 && tourArrow('ArrowLeft', false) === -1, 'the arrows move the tour');
        ok(tourArrow('ArrowRight', true) === 0 && tourArrow('ArrowLeft', true) === 0, 'covered: the arrows do nothing');
        ok(tourArrow('Enter', false) === 0, 'another key does nothing');
    }
}
