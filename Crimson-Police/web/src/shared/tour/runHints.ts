// The tips of the first mission run (the 'run' tour of Config.Training): which tips show this time, which one is
// next for what is on screen now (the HUD, its objectives, its GPS line, the result card) and when they are finished.
// RunHints.tsx shows them; there is no NUI focus during a run, so a tip closes by itself after hintSeconds.

import type { HudState } from '../types';
import type { TrainingView } from './store';
import { TOURS, stepsToShow, type HintWhen, type TourCtx, type TourStep } from './tours';

const NO_CTX: TourCtx = { session: null, screens: [], deptTabs: [], checklist: false };

// What of the run is on screen now.
export type HintCond = Record<HintWhen, boolean>;

// The HUD's GPS line shows: the route line (to the start, or while on, off or following the route) or the objective
// pointer during the objectives (the same rules as hud/Hud.tsx's showRoute and TargetLine; keep both in step).
export function hudRouteShown(hud: HudState): boolean {
    return (
        !!hud.route &&
        (hud.phase === 'route' ||
            hud.route.status === 'on' ||
            hud.route.status === 'off' ||
            hud.route.status === 'action')
    );
}

export function hudTargetShown(hud: HudState): boolean {
    return hud.phase === 'objectives' && !!hud.target;
}

// hud: the HUD on screen (null while hidden, e.g. under the open Officer UI); result: the result card on screen.
export function hintCond(hud: HudState | null, result: boolean): HintCond {
    return {
        hud: !!hud,
        objectives: !!hud && (hud.objectives?.length ?? 0) > 0,
        gps: !!hud && (hudRouteShown(hud) || hudTargetShown(hud)),
        result,
    };
}

// The tips to show: every tip when asked for again (a Tours list, /crimsonhelp run); else, with the tours and
// autoStart.run on, the tips of a newer version than the one the player finished (all of them the first time).
export function hintsToShow(view: TrainingView | null, again: boolean): TourStep[] {
    if (!view || !view.enabled) return [];
    const tour = TOURS.run;
    if (again) return tour.steps;
    if (view.autoStart.run === false) return [];
    return stepsToShow(tour, view.seen.run ?? 0, false, NO_CTX);
}

// The next tip: the first one not shown yet whose part of the run is on screen now.
export function nextHint(steps: TourStep[], shown: ReadonlySet<string>, cond: HintCond): TourStep | null {
    return steps.find(s => !shown.has(s.id) && !!s.when && cond[s.when]) ?? null;
}

// Finished (saved, so the tips do not show again): every tip shown, or the result card's tip (the run is over; a tip
// whose part never came in this run, e.g. no GPS line, is not waited for).
export function hintsFinished(steps: TourStep[], shown: ReadonlySet<string>): boolean {
    if (steps.length === 0) return false;
    return steps.every(s => shown.has(s.id)) || steps.some(s => s.when === 'result' && shown.has(s.id));
}
