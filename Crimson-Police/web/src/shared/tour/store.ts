// The tour state shared by the whole NUI: the player's training view (training:get: Config.Training and the tours he
// finished), the tour running now and a tour asked for (the '?' button, a Tours list, /crimsonhelp, the end of the
// First-start setup). TourHost (shared/tour/TourHost.tsx) runs it; anything may ask with askTour().

import { useSyncExternalStore } from 'react';
import { action } from '../nui';
import { TOURS, tourVersion, type TourId, type TourTablet } from './tours';

// training:get (modules/access/training.lua)
export interface TrainingView {
    enabled: boolean;
    autoStart: Partial<Record<TourId, boolean>>;
    allowSkip: boolean;
    checklist?: boolean;
    seen: Partial<Record<TourId, number>>;
    versions?: Partial<Record<TourId, number>>;
    // an admin with the First-start setup still on Home: the Admin tour waits for the setup's last page
    setupPending?: boolean;
}

export interface TourRun {
    tour: TourId;
    // the ids of the steps it shows, in order
    steps: string[];
    index: number;
}

interface TourState {
    view: TrainingView | null;
    run: TourRun | null;
    // asked for, waiting for its tablet to show (dropped after ASK_TTL_MS)
    asked: { tour: TourId; at: number } | null;
}

const ASK_TTL_MS = 10000;

let state: TourState = { view: null, run: null, asked: null };
const listeners = new Set<() => void>();

function set(patch: Partial<TourState>): void {
    state = { ...state, ...patch };
    listeners.forEach(fn => fn());
}

function subscribe(fn: () => void): () => void {
    listeners.add(fn);
    return () => listeners.delete(fn);
}

export function tourState(): TourState {
    return state;
}

export function useTourState(): TourState {
    return useSyncExternalStore(subscribe, tourState, tourState);
}

// Lua sends an empty table as [] or {}: a map of tour -> number either way.
function versionsOf(v: unknown): Partial<Record<TourId, number>> {
    const out: Partial<Record<TourId, number>> = {};
    if (!v || typeof v !== 'object' || Array.isArray(v)) return out;
    for (const [k, n] of Object.entries(v as Record<string, unknown>)) {
        if (k in TOURS && typeof n === 'number' && n > 0) out[k as TourId] = Math.floor(n);
    }
    return out;
}

export function normalizeTraining(raw: unknown): TrainingView | null {
    if (!raw || typeof raw !== 'object') return null;
    const r = raw as Record<string, unknown>;
    const auto: Partial<Record<TourId, boolean>> = {};
    const a = r.autoStart && typeof r.autoStart === 'object' ? (r.autoStart as Record<string, unknown>) : {};
    for (const id of Object.keys(TOURS) as TourId[]) auto[id] = a[id] !== false;
    return {
        enabled: r.enabled !== false,
        autoStart: auto,
        allowSkip: r.allowSkip !== false,
        checklist: r.checklist !== false,
        seen: versionsOf(r.seen),
        versions: versionsOf(r.versions),
        setupPending: r.setupPending === true,
    };
}

export function setTrainingView(view: TrainingView | null): void {
    set({ view });
}

// The tour that starts by itself on this tablet: tours on, its autoStart on, an older version (or none) finished,
// and for the Admin UI no First-start setup waiting on Home (its last page offers the tour).
export function autoTourFor(tablet: TourTablet, view: TrainingView | null): TourId | null {
    if (!view || !view.enabled) return null;
    for (const id of Object.keys(TOURS) as TourId[]) {
        if (TOURS[id].tablet !== tablet || view.autoStart[id] === false) continue;
        if (id === 'admin' && view.setupPending) continue;
        if ((view.seen[id] ?? 0) < tourVersion(TOURS[id])) return id;
    }
    return null;
}

// Ask for a tour from the start (it runs once its tablet shows). Ignored while tours are off.
export function askTour(tour: TourId): void {
    if (state.view && !state.view.enabled) return;
    set({ asked: { tour, at: Date.now() } });
}

// The asked tour for this tablet, if one is waiting (and still fresh); it is taken off the queue.
export function takeAsked(tablet: TourTablet, now: number = Date.now()): TourId | null {
    const a = state.asked;
    if (!a) return null;
    if (now - a.at > ASK_TTL_MS) {
        set({ asked: null });
        return null;
    }
    if (TOURS[a.tour].tablet !== tablet) return null;
    set({ asked: null });
    return a.tour;
}

export function beginRun(tour: TourId, steps: string[]): void {
    if (steps.length === 0) return;
    set({ run: { tour, steps, index: 0 } });
}

export function moveRun(delta: number): void {
    const r = state.run;
    if (!r) return;
    const index = Math.max(0, Math.min(r.steps.length - 1, r.index + delta));
    if (index !== r.index) set({ run: { ...r, index } });
}

// Ends the tour. save = it was finished or the player chose Don't show again: the server keeps its version, so it
// does not start by itself again.
export function endRun(save: boolean): void {
    const r = state.run;
    if (!r) return;
    set({ run: null });
    if (!save) return;
    const version = tourVersion(TOURS[r.tour]);
    if (state.view) set({ view: { ...state.view, seen: { ...state.view.seen, [r.tour]: version } } });
    void action('server:training:done', { tour: r.tour, version });
}
