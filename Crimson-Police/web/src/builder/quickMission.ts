// The New mission wizard (Config.Builder.quickWizard) without React: its steps, what a location still misses, what
// "Fill the points for me" fills, the name it proposes and the check list. QuickMission.tsx draws it; the browser
// walk-through (quickMission.walk.ts) runs the same helpers against the mocks.

import type { BuilderConfig, BuilderError, BuilderLocation } from '../types/builder_server';
import type { BuilderStepKey, PointSpec } from '../types/builder_client';
import { isRoute, listsOf, locationOfError, objectiveOfError, pointsOf, stepOfError } from './defUtils';

export type QuickStep = 'what' | 'where' | 'check' | 'publish';
export const QUICK_STEPS: QuickStep[] = ['what', 'where', 'check', 'publish'];

// the full editor step "Open the full editor" opens from each wizard step
export const FULL_STEP: Record<QuickStep, BuilderStepKey> = {
    what: 'blocks',
    where: 'locations',
    check: 'publish',
    publish: 'publish',
};

// What a "New mission" press opens: the wizard (Config.Builder.quickWizard, missing = on) or the New mission dialog
export function newMissionOpens(config: Pick<BuilderConfig, 'quickWizard'> | null | undefined): 'wizard' | 'dialog' {
    return config && config.quickWizard === false ? 'dialog' : 'wizard';
}

// The navigate() params of Home's "Make a new mission" tile: Admin UI -> Missions, Builder tab, New mission pressed
export const NEW_MISSION_PARAMS = { tab: 'builder', wizard: 'new' } as const;

// The params ask for New mission (the Missions screen then opens the wizard, or the dialog when it is off)
export function asksNewMission(params: Record<string, unknown> | null | undefined): boolean {
    return !!params && params.wizard === 'new';
}

// "Fill N for me" fills keys of people or vehicles with many points that appear around a start (Config.Builder.autoFill)
export function canAutoFill(spec: PointSpec): boolean {
    return spec.multiple && !spec.lists && !!spec.spawn && (spec.kind === 'ped' || spec.kind === 'vehicle');
}

export interface PointNeed {
    spec: PointSpec;
    have: number;
    need: number;
}

// Points a key holds and the least it needs (as the Locations step's point row counts them).
export function pointNeed(spec: PointSpec, loc: BuilderLocation): PointNeed {
    const v = loc[spec.key];
    const have =
        spec.kind === 'route'
            ? isRoute(v)
                ? v.points.length
                : pointsOf(v).length
            : spec.lists
              ? listsOf(v).length
              : pointsOf(v).length;
    const need = spec.lists ? 1 : spec.kind === 'route' ? Math.max(2, spec.min) : spec.min;
    return { spec, have, need };
}

// Every key of the location that still has fewer points than it needs, in the order of the specs.
export function missingPoints(specs: PointSpec[], loc: BuilderLocation | undefined): PointNeed[] {
    if (!loc) return [];
    return specs.map(s => pointNeed(s, loc)).filter(n => n.have < n.need);
}

export interface FillTask {
    spec: PointSpec;
    count: number;
}

// What "Fill the points for me" asks the game for: each fillable key's missing points up to its least (never past
// its most). Nothing without a start (the points go around it).
export function fillPlan(specs: PointSpec[], loc: BuilderLocation | undefined): FillTask[] {
    if (!loc || !loc.start) return [];
    const out: FillTask[] = [];
    specs.forEach(s => {
        if (!canAutoFill(s)) return;
        const { have } = pointNeed(s, loc);
        const count = Math.max(0, Math.min(s.min, s.max) - have);
        if (count > 0) out.push({ spec: s, count });
    });
    return out;
}

// The name the wizard proposes once the start is placed: "<template> - <street at the start>", cut to max.
export function wizardName(base: string, street: string | undefined | null, max = 64): string {
    const b = base.trim();
    const s = (street ?? '').trim();
    if (!s) return b.slice(0, max);
    return `${b} - ${s}`.slice(0, max).trim();
}

// The wizard renames the mission only while it still has the name it was created with (or none): a name the builder
// typed is kept.
export function keepsBaseName(label: string, base: string): boolean {
    const l = label.trim();
    return l === '' || l === base.trim();
}

export interface CheckGroup {
    step: BuilderStepKey;
    messages: string[];
    objective?: number;
    location?: number;
}

const ORDER: BuilderStepKey[] = ['blocks', 'details', 'settings', 'locations', 'scaling', 'test', 'publish'];

// The check list: the problems in plain words, one group per editor step (its Fix button opens that step there).
export function checkGroups(errors: BuilderError[]): CheckGroup[] {
    const out: CheckGroup[] = [];
    ORDER.forEach(step => {
        const list = errors.filter(e => stepOfError(e) === step);
        if (!list.length) return;
        const messages: string[] = [];
        list.forEach(e => {
            const m = (e.message || e.key || '').trim();
            if (m && !messages.includes(m)) messages.push(m);
        });
        out.push({
            step,
            messages,
            objective: objectiveOfError(list[0]) ?? undefined,
            location: locationOfError(list[0]) ?? undefined,
        });
    });
    return out;
}

// The first location without a start (where the wizard works), else the last one.
export function workLocation(locations: BuilderLocation[]): number {
    const i = locations.findIndex(l => !l.start);
    return i >= 0 ? i + 1 : Math.max(1, locations.length);
}
