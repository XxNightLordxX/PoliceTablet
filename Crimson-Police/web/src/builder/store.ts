// Module-level memory of the Mission Builder.

import type { BuilderDefinition } from '../types/builder_server';
import type {
    BuilderClientResultEx,
    BuilderStepKey,
    BuilderTestMemory,
    PointSpec,
    RouteMeta,
} from '../types/builder_client';

export type BuilderScope = 'sup' | 'admin';

export interface EditorMemory {
    openId: string | null;
    step: BuilderStepKey;
    // selected location (1-based) on the Locations step
    location: number;
    // selected objective (1-based) on the Block settings step
    objective: number;
    // Admin UI → Missions tab
    tab?: 'catalog' | 'builder' | 'operation';
}

export interface DraftMemory {
    id: string;
    def: BuilderDefinition;
    dirty: boolean;
    at: number;
}

export interface ToolMemory {
    kind: 'placement' | 'recording' | 'testdrive';
    missionId: string;
    location: number;
    key: string;
    spec: PointSpec | null;
    scope: BuilderScope;
    startedAt: number;
}

const editors: Record<BuilderScope, EditorMemory> = {
    sup: { openId: null, step: 'blocks', location: 1, objective: 1 },
    admin: { openId: null, step: 'blocks', location: 1, objective: 1, tab: 'catalog' },
};
let draft: DraftMemory | null = null;
let tool: ToolMemory | null = null;
const routeMeta = new Map<string, RouteMeta>();
const tests = new Map<string, BuilderTestMemory>();
const results: BuilderClientResultEx[] = [];
const seen = new Set<string>();
const listeners = new Set<() => void>();

function emit() {
    listeners.forEach(fn => {
        try {
            fn();
        } catch {
            // a listener's own problem
        }
    });
}

// Subscribe to changes (results arriving, tool state). Returns the unsubscribe function.
export function subscribeBuilder(fn: () => void): () => void {
    listeners.add(fn);
    return () => {
        listeners.delete(fn);
    };
}

// ============================================================================
//                                EDITOR MEMORY
// ============================================================================

export function editorMemory(scope: BuilderScope): EditorMemory {
    return editors[scope];
}

export function setEditorMemory(scope: BuilderScope, patch: Partial<EditorMemory>): void {
    editors[scope] = { ...editors[scope], ...patch };
    emit();
}

// ============================================================================
//                                 LOCAL DRAFT
// ============================================================================

export function rememberDraft(id: string, def: BuilderDefinition, dirty: boolean): void {
    draft = { id, def, dirty, at: Date.now() };
}

export function recallDraft(id: string): DraftMemory | null {
    return draft && draft.id === id ? draft : null;
}

export function forgetDraft(id?: string): void {
    if (!id || (draft && draft.id === id)) draft = null;
}

// A renamed mission (save of a never-published draft) keeps its memory under the new id.
export function renameMission(previousId: string, id: string): void {
    if (draft && draft.id === previousId) draft = { ...draft, id };
    (Object.keys(editors) as BuilderScope[]).forEach(s => {
        if (editors[s].openId === previousId) editors[s] = { ...editors[s], openId: id };
    });
    if (tool && tool.missionId === previousId) tool = { ...tool, missionId: id };
    for (const [k, v] of [...routeMeta.entries()]) {
        if (k.startsWith(`${previousId}:`)) {
            routeMeta.delete(k);
            routeMeta.set(id + k.slice(previousId.length), v);
        }
    }
    const test = tests.get(previousId);
    if (test) {
        tests.delete(previousId);
        tests.set(id, { ...test, missionId: id });
    }
    emit();
}

// ============================================================================
//                                    TOOLS
// ============================================================================

export function setTool(t: ToolMemory | null): void {
    tool = t;
    emit();
}

export function currentTool(): ToolMemory | null {
    return tool;
}

// ============================================================================
//                                  ROUTE META
// ============================================================================

const metaKey = (missionId: string, location: number, key: string) => `${missionId}:${location}:${key}`;

export function routeMetaOf(missionId: string, location: number, key: string): RouteMeta | null {
    return routeMeta.get(metaKey(missionId, location, key)) ?? null;
}

export function setRouteMeta(missionId: string, location: number, key: string, patch: Partial<RouteMeta> | null): void {
    const k = metaKey(missionId, location, key);
    if (patch === null) routeMeta.delete(k);
    else {
        const prev = routeMeta.get(k) ?? { length: 0, rejected: 0, rejectedSamples: [], unreachable: [] };
        routeMeta.set(k, { ...prev, ...patch });
    }
    emit();
}

// Location indexes shift when a location is removed: move the meta along.
export function shiftRouteMeta(missionId: string, removedLocation: number): void {
    const moved: [string, RouteMeta][] = [];
    for (const [k, v] of [...routeMeta.entries()]) {
        const m = k.match(/^(.*):(\d+):([^:]+)$/);
        if (!m || m[1] !== missionId) continue;
        const loc = Number(m[2]);
        if (loc === removedLocation) routeMeta.delete(k);
        else if (loc > removedLocation) {
            routeMeta.delete(k);
            moved.push([metaKey(missionId, loc - 1, m[3]), v]);
        }
    }
    moved.forEach(([k, v]) => routeMeta.set(k, v));
    emit();
}

// ============================================================================
//                                 DRAFT TESTS
// ============================================================================

export function lastTest(missionId: string): BuilderTestMemory | null {
    return tests.get(missionId) ?? null;
}

export function setLastTest(missionId: string, test: BuilderTestMemory | null): void {
    if (test) tests.set(missionId, test);
    else tests.delete(missionId);
    emit();
}

// ============================================================================
//                                 TOOL RESULTS
// ============================================================================

function resultKey(r: BuilderClientResultEx): string {
    return r.seq !== undefined && r.seq !== null ? `seq:${r.seq}` : `json:${JSON.stringify(r)}`;
}

// Queue a result (from a push or a builderResult pull). Duplicates are ignored. The running tool stays until its
// result is applied (useDraftEditor.applyPending): its PointSpec says how the result is written.
export function queueResult(r: unknown): void {
    if (!r || typeof r !== 'object') return;
    const res = r as BuilderClientResultEx;
    if (typeof res.missionId !== 'string' || typeof res.kind !== 'string') return;
    const k = resultKey(res);
    if (seen.has(k)) return;
    seen.add(k);
    results.push(res);
    emit();
}

// Take (remove) every queued result of one mission, oldest first.
export function takeResults(missionId: string): BuilderClientResultEx[] {
    const mine: BuilderClientResultEx[] = [];
    for (let i = 0; i < results.length;) {
        if (results[i].missionId === missionId) {
            mine.push(results[i]);
            results.splice(i, 1);
        } else i += 1;
    }
    return mine;
}

export function hasResults(missionId: string): boolean {
    return results.some(r => r.missionId === missionId);
}

// The push arrives while the tablet is closed (no screen mounted): listen at module level.
if (typeof window !== 'undefined') {
    window.addEventListener('message', (event: MessageEvent) => {
        const data = event.data as {
            type?: string;
            topic?: string;
            data?: { event?: string; result?: unknown };
        } | null;
        if (!data || data.type !== 'push' || data.topic !== 'builder') return;
        if (data.data && data.data.event === 'clientResult') queueResult(data.data.result);
    });
}
