// Check spawn points (PLAN S8): the admin's check kept in module memory, fed by the Lua testing client's pushes.

import { useSyncExternalStore } from 'react';
import { t } from '../../shared/i18n';
import { clientAction } from '../../shared/nui';
import { toast } from '../../shared/toast';
import type { ApiResult } from '../../shared/types';
import {
    asList,
    type SpawnCheckProgress,
    type SpawnCheckPush,
    type SpawnCheckResult,
    type SpawnCheckScope,
    type SpawnCheckTotals,
    type SpawnProbeStatus,
} from '../../types/testing';

// The push arrives while the tablet is closed or the Testing screen is not open, so it is kept here, not in a screen.

export type SpawnCheckStatus = 'idle' | 'running' | 'done' | 'stopped' | 'failed';

// A checked point with the mission and location it belongs to.
export interface SpawnCheckRow extends SpawnCheckResult {
    missionId: string;
    missionLabel: string;
    location: number;
    locationLabel: string;
}

// A location the check could not ask for (the server refused it), with why.
export interface SpawnCheckSkipped {
    missionId: string;
    missionLabel: string;
    location: number;
    error: string;
}

export interface SpawnCheckView {
    status: SpawnCheckStatus;
    scope: SpawnCheckScope | null;
    planned: { missions: number; locations: number } | null;
    progress: SpawnCheckProgress | null;
    // the location being checked now
    current: { missionId: string; missionLabel: string; location: number; locationLabel: string } | null;
    // how many locations the check has reached (the one being checked included)
    reached: number;
    rows: SpawnCheckRow[];
    skipped: SpawnCheckSkipped[];
    totals: SpawnCheckTotals | null;
    error: string | null;
    stopping: boolean;
    startedAt: number | null;
    endedAt: number | null;
}

const EMPTY: SpawnCheckView = {
    status: 'idle',
    scope: null,
    planned: null,
    progress: null,
    current: null,
    reached: 0,
    rows: [],
    skipped: [],
    totals: null,
    error: null,
    stopping: false,
    startedAt: null,
    endedAt: null,
};

let view: SpawnCheckView = EMPTY;
let pendingScope: SpawnCheckScope | null = null;
let awaitingStart = false;
const listeners = new Set<() => void>();

function set(patch: Partial<SpawnCheckView>) {
    view = { ...view, ...patch };
    listeners.forEach(fn => {
        try {
            fn();
        } catch {
            // a listener's own problem
        }
    });
}

export function spawnCheckView(): SpawnCheckView {
    return view;
}

export function subscribeSpawnCheck(fn: () => void): () => void {
    listeners.add(fn);
    return () => {
        listeners.delete(fn);
    };
}

export function useSpawnCheck(): SpawnCheckView {
    return useSyncExternalStore(subscribeSpawnCheck, spawnCheckView, spawnCheckView);
}

// A point to look at: everything but ok and skipped (the server writes a console line for each of these).
export function isBad(status: SpawnProbeStatus | string): boolean {
    return status !== 'ok' && status !== 'skipped';
}

function begin(scope: SpawnCheckScope | null, planned: { missions: number; locations: number } | null) {
    set({ ...EMPTY, status: 'running', scope, planned, startedAt: Date.now() });
}

function numberOr(v: unknown, fallback: number): number {
    return typeof v === 'number' && Number.isFinite(v) ? v : fallback;
}

// One 'spawnCheck' push from the Lua testing client (modules/testing/client.lua PushCheck).
export function applySpawnCheckPush(d: SpawnCheckPush | null | undefined): void {
    if (!d || typeof d !== 'object') return;
    // a check this memory missed the start of (the page reloaded meanwhile): follow it from here
    if ((d.state === 'location' || d.state === 'point') && view.status !== 'running') begin(view.scope, null);
    switch (d.state) {
        case 'started':
            awaitingStart = false;
            begin(pendingScope, { missions: numberOr(d.missions, 0), locations: numberOr(d.locations, 0) });
            return;
        case 'location': {
            const missionId = typeof d.missionId === 'string' ? d.missionId : '';
            const location = numberOr(d.location, 0);
            const missionLabel = typeof d.missionLabel === 'string' ? d.missionLabel : missionId;
            const progress = d.progress ?? view.progress;
            if (d.error) {
                set({
                    progress,
                    reached: view.reached + 1,
                    skipped: [...view.skipped, { missionId, missionLabel, location, error: String(d.error) }],
                });
                return;
            }
            set({
                progress,
                reached: view.reached + 1,
                current: {
                    missionId,
                    missionLabel,
                    location,
                    locationLabel: typeof d.locationLabel === 'string' ? d.locationLabel : '',
                },
            });
            return;
        }
        case 'point': {
            const r = d.result;
            if (!r || typeof r.id !== 'string') return;
            const cur = view.current;
            const missionId = typeof d.missionId === 'string' ? d.missionId : (cur?.missionId ?? '');
            const location = numberOr(d.location, cur?.location ?? 0);
            const same = !!cur && cur.missionId === missionId && cur.location === location;
            const row: SpawnCheckRow = {
                ...r,
                near: asList(r.near),
                missionId,
                missionLabel: same ? cur.missionLabel : missionId,
                location,
                locationLabel: same ? cur.locationLabel : '',
            };
            set({ rows: [...view.rows, row], progress: d.progress ?? view.progress });
            return;
        }
        case 'done':
        case 'stopped':
        case 'failed': {
            const error = d.state === 'failed' ? String(d.error || 'err.internal') : null;
            set({
                status: d.state,
                progress: d.progress ?? view.progress,
                totals: d.totals ?? null,
                error,
                stopping: false,
                current: null,
                endedAt: Date.now(),
            });
            const bad = d.totals ? d.totals.bad : view.rows.filter(r => isBad(r.status)).length;
            if (d.state === 'failed') toast('error', t('test.ui.spawn.toast_failed', { reason: t(error || '') }));
            else toast(bad > 0 ? 'warning' : 'success', t(`test.ui.spawn.toast_${d.state}`, { bad }));
            return;
        }
        default:
            return;
    }
}

// Start a check (client action 'spawnCheck'): every mission, one mission or one location.
export async function startSpawnCheck(
    scope: SpawnCheckScope,
): Promise<ApiResult<{ started: boolean; missions: number; locations: number }>> {
    pendingScope = scope;
    awaitingStart = true;
    const res = await clientAction<{ started: boolean; missions: number; locations: number }>('spawnCheck', scope);
    // the 'started' push and this answer come on two channels: whichever is first starts the memory
    if (res.ok && awaitingStart) {
        begin(scope, res.data ? { missions: res.data.missions, locations: res.data.locations } : null);
    }
    awaitingStart = false;
    return res;
}

// Stop it after the point being checked (client action 'spawnCheckStop').
export async function stopSpawnCheck(): Promise<ApiResult<{ stopping: boolean }>> {
    set({ stopping: true });
    const res = await clientAction<{ stopping: boolean }>('spawnCheckStop');
    if (!res.ok) set({ stopping: false });
    // the game has no check running (its end never reached this page): end it here too
    else if (res.data && res.data.stopping === false && view.status === 'running') {
        set({ status: 'stopped', stopping: false, current: null, endedAt: Date.now() });
    }
    return res;
}

// ============================================================================
//                                  THE REPORT
// ============================================================================
// One line per point to look at, in the server's console format (modules/testing/server.lua ReportLine, the same
// status words as CHECK_STATUS), so a pasted report reads like the console.

const STATUS_WORD: Record<SpawnProbeStatus, string> = {
    ok: 'OK',
    snap: 'HEIGHT OFF',
    underground: 'UNDERGROUND',
    floating: 'FLOATING',
    no_ground: 'NO GROUND',
    in_water: 'IN WATER',
    in_wall: 'IN A WALL',
    interior_not_loaded: 'INSIDE NOT LOADED',
    skipped: 'SKIPPED',
};

function isNum(v: unknown): v is number {
    return typeof v === 'number' && Number.isFinite(v);
}

export function reportLine(r: SpawnCheckRow): string {
    const notes: string[] = [r.kind];
    asList(r.near).forEach(n => {
        if (n === 'start' && isNum(r.dStart)) notes.push(`${r.dStart.toFixed(1)} m from the start`);
        if (n === 'previous' && isNum(r.dPrevious)) notes.push(`${r.dPrevious.toFixed(1)} m from the objective before`);
    });
    if (r.seen === true) notes.push('seen from the start');
    const ground = isNum(r.groundZ) ? r.groundZ.toFixed(2) : 'none';
    const dz = isNum(r.dz) ? `${r.dz >= 0 ? '+' : ''}${r.dz.toFixed(2)}` : '-';
    const word = STATUS_WORD[r.status] ?? String(r.status).toUpperCase();
    return (
        `spawn check: ${r.missionId} #${r.location} ${r.id} (${r.x.toFixed(2)}, ${r.y.toFixed(2)}, ${r.z.toFixed(2)}) ` +
        `${word} ground ${ground} (${dz}) [${notes.join('; ')}]`
    );
}

// The whole report: a summary line, every point to look at, and the locations that could not be checked.
export function spawnCheckReport(v: SpawnCheckView): string {
    const bad = v.rows.filter(r => isBad(r.status));
    const locations = new Set(v.rows.map(r => `${r.missionId}#${r.location}`)).size;
    const when = new Date(v.startedAt ?? Date.now()).toISOString().replace('T', ' ').slice(0, 16);
    const lines = [
        t('test.ui.spawn.report_head', { when, points: v.rows.length, locations, bad: bad.length }),
        ...bad.map(reportLine),
        ...v.skipped.map(s =>
            t('test.ui.spawn.report_skipped', { mission: s.missionId, n: s.location, reason: t(s.error) }),
        ),
    ];
    if (v.status === 'running') lines.push(t('test.ui.spawn.report_running'));
    else if (v.status === 'stopped') lines.push(t('test.ui.spawn.report_stopped'));
    else if (v.status === 'failed') lines.push(t('test.ui.spawn.report_failed', { reason: t(v.error || '') }));
    return lines.join('\n');
}

// Browser specs and the dev panel: forget the check.
export function resetSpawnCheck(): void {
    pendingScope = null;
    awaitingStart = false;
    set({ ...EMPTY });
}

if (typeof window !== 'undefined') {
    window.addEventListener('message', (event: MessageEvent) => {
        const d = event.data as { type?: string; topic?: string; data?: SpawnCheckPush } | null;
        if (!d || d.type !== 'push' || d.topic !== 'spawnCheck') return;
        applySpawnCheckPush(d.data);
    });
}
