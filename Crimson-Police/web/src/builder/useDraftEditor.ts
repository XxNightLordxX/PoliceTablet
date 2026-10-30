// One open mission in the Mission Builder (docs/notes/builder_protocol.md §2–§6).

import { useCallback, useEffect, useRef, useState } from 'react';
import { usePush } from '../shared/hooks';
import { t } from '../shared/i18n';
import { action, clientAction, isTabletShown, request } from '../shared/nui';
import { toast } from '../shared/toast';
import type {
    BuilderAutosaveResult,
    BuilderConfig,
    BuilderDefinition,
    BuilderError,
    BuilderLock,
    BuilderLockResult,
    BuilderPush,
    BuilderRecord,
    BuilderSaveResult,
    BuilderValidateResult,
    Vec3,
} from '../types/builder_server';
import type {
    BuilderAutoPointsReply,
    BuilderAutoPointsRequest,
    BuilderCheckPointsKey,
    BuilderCheckPointsReply,
    BuilderCheckPointsRequest,
    BuilderClientResultEx,
    BuilderHereReply,
    BuilderPlaceRequest,
    BuilderRecordRequest,
    BuilderTestDriveRequest,
    BuilderUi,
    PointSpec,
} from '../types/builder_client';
import { applyResult } from './applyResult';
import { clone, isRoute, labelSlug, listsOf, normalizeDefinition, pointsOf, vecsOf } from './defUtils';
import { pointsWithout, removePointAt, resultReplacing } from './pointList';
import { armedKeepOut, searchCircleOf, startRadiusRange, syncStartRadius } from './schema';
import {
    currentTool,
    forgetDraft,
    queueResult,
    recallDraft,
    rememberDraft,
    renameMission,
    routeMetaOf,
    setRouteMeta,
    setTool,
    subscribeBuilder,
    takeResults,
    type BuilderScope,
} from './store';

// What "Move the whole location here" did: how far the start moved, the points moved, and per key the moved points
// that need a new spot (1-based indexes, with why) and the routes that only moved
export interface MoveReport {
    location: number;
    // where the start is now
    start: Vec3;
    dist: number;
    moved: number;
    failed: { key: string; points: { index: number; reason: string }[] }[];
    routes: string[];
}

export type ReadOnlyReason = 'builtin' | 'archived' | 'permission' | 'locked' | 'lost' | null;

export interface DraftEditor {
    id: string;
    record: BuilderRecord | null;
    def: BuilderDefinition | null;
    loading: boolean;
    error: string | null;
    readOnly: boolean;
    readOnlyReason: ReadOnlyReason;
    lock: BuilderLock | null;
    lockLostBy: string | null;
    dirty: boolean;
    saving: boolean;
    savedAt: number | null;
    errors: BuilderError[];
    armedServer: number | null;
    validating: boolean;
    toolBusy: boolean;
    update: (fn: (d: BuilderDefinition) => void) => void;
    save: (opts?: { quiet?: boolean }) => Promise<boolean>;
    autosaveNow: () => Promise<boolean>;
    // store unsaved changes now (autosave; an explicit save when autosave is rate-limited or the label renames a
    // never-published draft). The id the draft is stored under (a rename changes it), null = not stored
    flush: () => Promise<string | null>;
    // drop the local draft and load the mission again (after publish / discard)
    reload: (opts?: { lock?: boolean }) => Promise<void>;
    // the mission is gone (deleted): close the editor
    gone: () => void;
    validateNow: () => Promise<BuilderValidateResult | null>;
    refresh: () => Promise<void>;
    takeLock: () => Promise<boolean>;
    releaseLock: () => Promise<void>;
    place: (spec: PointSpec, location: number) => Promise<boolean>;
    // the point where the player stands (Config.Builder.useMyPosition): set or added at once, the tablet stays open.
    // With index (1-based, a multiple key): that point is moved there (the point list's "Set here"). onReply sees the
    // game's answer (a start names its street: the New mission wizard names the mission after it)
    here: (
        spec: PointSpec,
        location: number,
        index?: number,
        onReply?: (reply: BuilderHereReply) => void,
    ) => Promise<boolean>;
    // the point list's Delete: point index (1-based) of a key goes, stored at once (autosave)
    removePoint: (key: string, location: number, index: number) => Promise<boolean>;
    // "Fill N for me" (Config.Builder.autoFill): the game proposes count new points around the start; the draft does
    // not change until keepFill applies the reply's result (null: refused, the toast says why)
    // drop: points (1-based) the proposal replaces (the moved points that failed their check)
    autoFill: (
        spec: PointSpec,
        location: number,
        count: number,
        drop?: number[],
    ) => Promise<BuilderAutoPointsReply | null>;
    keepFill: (spec: PointSpec, result: BuilderClientResultEx) => Promise<boolean>;
    // "Move the whole location here" (Config.Builder.useMyPosition): the start goes where the player stands and every
    // point of the location moves with it; each moved point is put on the ground and checked again (builderCheckPoints).
    // One autosave. null: nothing changed (the toast says why)
    moveLocation: (location: number, specs: PointSpec[]) => Promise<MoveReport | null>;
    recordRoute: (spec: PointSpec, location: number) => Promise<boolean>;
    testDrive: (spec: PointSpec, location: number) => Promise<boolean>;
}

const VALIDATE_DELAY_MS = 1500;
const START_SPEC: PointSpec = {
    key: 'start',
    field: 'start',
    labelKey: 'builder.points.start',
    kind: 'start',
    heading: false,
    multiple: false,
    min: 1,
    max: 1,
    spawn: false,
    objective: 0,
};

export function startSpec(): PointSpec {
    return START_SPEC;
}

export function useDraftEditor(
    id: string,
    scope: BuilderScope,
    ui: BuilderUi,
    config: BuilderConfig | null,
    onRenamed: (id: string) => void,
    onGone: () => void,
): DraftEditor {
    const [record, setRecord] = useState<BuilderRecord | null>(null);
    const [def, setDef] = useState<BuilderDefinition | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [lock, setLock] = useState<BuilderLock | null>(null);
    const [lockLostBy, setLockLostBy] = useState<string | null>(null);
    const [dirty, setDirty] = useState(false);
    const [saving, setSaving] = useState(false);
    const [savedAt, setSavedAt] = useState<number | null>(null);
    const [errors, setErrors] = useState<BuilderError[]>([]);
    const [armedServer, setArmedServer] = useState<number | null>(null);
    const [validating, setValidating] = useState(false);
    const [toolBusy, setToolBusy] = useState(false);

    const idRef = useRef(id);
    idRef.current = id;
    const defRef = useRef<BuilderDefinition | null>(null);
    defRef.current = def;
    const rev = useRef(0);
    const dirtyRef = useRef(false);
    dirtyRef.current = dirty;
    const lockRef = useRef<BuilderLock | null>(null);
    lockRef.current = lock;
    const recordRef = useRef<BuilderRecord | null>(null);
    recordRef.current = record;
    const configRef = useRef<BuilderConfig | null>(config);
    configRef.current = config;
    const mounted = useRef(true);

    const lockHeld = !!(lock && lock.mine);
    let readOnlyReason: ReadOnlyReason = null;
    if (record) {
        if (record.source === 'builtin') readOnlyReason = 'builtin';
        else if (record.dbStatus === 'archived') readOnlyReason = 'archived';
        else if (lockLostBy) readOnlyReason = 'lost';
        else if (lockHeld) readOnlyReason = null;
        else if (record.lock && !record.lock.mine) readOnlyReason = 'locked';
        else if (!record.can.edit) readOnlyReason = 'permission';
        else readOnlyReason = 'locked';
    }
    const readOnly = readOnlyReason !== null;

    useEffect(() => {
        mounted.current = true;
        return () => {
            mounted.current = false;
        };
    }, []);

    // ---- LOAD --------------------------------------------------------------
    const fetchRecord = useCallback(async (): Promise<BuilderRecord | null> => {
        const res = await request<BuilderRecord>('builder:get', { id: idRef.current });
        if (!mounted.current) return null;
        if (!res.ok || !res.data) {
            setError(res.error ?? 'err.internal');
            return null;
        }
        setError(null);
        setRecord(res.data);
        return res.data;
    }, []);

    const takeLock = useCallback(async (): Promise<boolean> => {
        const res = await action<BuilderLockResult>('server:builder:lock', { id: idRef.current });
        if (!mounted.current) return false;
        if (res.ok && res.data) {
            setLock(res.data.lock);
            setLockLostBy(null);
            return !!res.data.lock?.mine;
        }
        if (res.error && res.error !== 'err.builder_locked' && res.error !== 'err.builder_read_only')
            toast('error', t(res.error));
        return false;
    }, []);

    const applyPending = useCallback(async () => {
        // pull the Lua copy too (a push may have been missed); both are deduplicated by seq
        const pulled = await clientAction<BuilderClientResultEx | null>('builderResult', {});
        if (pulled.ok && pulled.data) queueResult(pulled.data);
        // not loaded yet: the results stay queued, load() applies them
        let next = defRef.current;
        if (!next) return;
        const list = takeResults(idRef.current);
        if (!list.length) return;
        const before = next;
        const tool = currentTool();
        let changed = false;
        for (const r of list) {
            const spec = tool && tool.missionId === r.missionId && tool.key === r.key ? tool.spec : null;
            const applied = applyResult(next, r, spec, config);
            if (applied.meta) setRouteMeta(r.missionId, r.location, r.key, applied.meta);
            if (applied.def) {
                next = applied.def;
                changed = true;
            }
            toast(applied.tone, t(applied.messageKey, applied.vars));
        }
        setTool(null);
        if (changed && next) {
            syncStartRadius(next, config, before);
            rev.current += 1;
            setDef(next);
            setDirty(true);
            rememberDraft(idRef.current, next, true);
        }
    }, [config]);

    // lock: false = only show the mission (after Publish the server released the lock; Edit again takes it)
    const load = useCallback(
        async (opts?: { lock?: boolean }) => {
            setLoading(true);
            const rec = await fetchRecord();
            if (!rec) {
                setLoading(false);
                return;
            }
            const memory = recallDraft(rec.id);
            const base = memory && memory.dirty ? memory.def : rec.definition;
            const d = normalizeDefinition(base);
            // a draft saved before the search-circle rule (start radius from the 20–150 m range): an editable one gets
            // its start radii put on the search circle at once, as a pending change, so the locked field shows what is
            // saved
            const editable =
                rec.source === 'custom' && rec.can.edit && rec.dbStatus !== 'archived' && !(rec.lock && !rec.lock.mine);
            const synced = editable && syncStartRadius(d, configRef.current);
            setDef(d);
            setDirty(!!(memory && memory.dirty) || synced);
            if (synced) rememberDraft(rec.id, d, true);
            setErrors(Array.isArray(rec.errors) ? rec.errors : []);
            setArmedServer(typeof rec.armed === 'number' ? rec.armed : null);
            setLockLostBy(null);
            if (opts?.lock !== false && editable) {
                await takeLock();
            } else {
                setLock(rec.lock && rec.lock.mine ? rec.lock : null);
            }
            if (!mounted.current) return;
            setLoading(false);
            await applyPending();
        },
        [fetchRecord, takeLock, applyPending],
    );

    // a save that renamed the draft already holds its record and lock under the new id: no second load
    const renamedTo = useRef<string | null>(null);
    useEffect(() => {
        if (renamedTo.current === id) {
            renamedTo.current = null;
            return;
        }
        void load();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [id]);

    // leaving the editor inside the tablet (the sidebar, another UI) releases the own edit lock; an unsaved change
    // stays in this tablet's memory and comes back when the mission is opened again. Closing the tablet (a Builder
    // tool hides it) keeps the lock: the editor comes back when it opens again.
    useEffect(
        () => () => {
            if (lockRef.current?.mine && isTabletShown()) void action('server:builder:unlock', { id: idRef.current });
        },
        [],
    );

    // results that arrive while the editor is open
    useEffect(
        () =>
            subscribeBuilder(() => {
                if (!loading && defRef.current) {
                    const tool = currentTool();
                    setToolBusy(!!tool && tool.missionId === idRef.current);
                }
            }),
        [loading],
    );
    usePush<BuilderPush>('builder', data => {
        if (!data || typeof data !== 'object') return;
        if (data.event === 'clientResult') {
            queueResult(data.result);
            if (data.id === idRef.current) void applyPending();
            return;
        }
        if (data.id !== idRef.current) return;
        switch (data.event) {
            case 'lockBroken':
                if (lockRef.current?.mine) {
                    setLockLostBy(data.by ?? t('builder.someone'));
                    setLock(null);
                }
                void fetchRecord();
                break;
            case 'deleted':
                forgetDraft(idRef.current);
                toast('warning', t('builder.editor.deleted'));
                onGone();
                break;
            case 'reloaded':
                // a hand edit of the Lua file was accepted: the file wins, the server cleared the draft and the lock
                void fetchRecord().then(rec => {
                    if (rec && !rec.hasDraft) {
                        const d = normalizeDefinition(rec.definition);
                        setDef(d);
                        setDirty(false);
                        forgetDraft(rec.id);
                    }
                    if (rec && lockRef.current?.mine && !(rec.lock && !rec.lock.mine)) void takeLock();
                });
                break;
            default:
                void fetchRecord();
        }
    });

    // ---- EDIT --------------------------------------------------------------
    const update = useCallback((fn: (d: BuilderDefinition) => void) => {
        const cur = defRef.current;
        if (!cur) return;
        const next = clone(cur);
        fn(next);
        // a search area's circle is the start marker: every start radius follows it (the server's guardrail)
        syncStartRadius(next, configRef.current, cur);
        rev.current += 1;
        defRef.current = next;
        setDef(next);
        setDirty(true);
        rememberDraft(idRef.current, next, true);
    }, []);

    const lockMine = () => !!(lockRef.current && lockRef.current.mine);

    // 'ok' stored · 'skip' nothing to store · 'rate' refused by the 5 s autosave limit · 'error' refused
    const autosaveRaw = useCallback(async (): Promise<'ok' | 'skip' | 'rate' | 'error'> => {
        const d = defRef.current;
        if (!d || !lockMine() || !dirtyRef.current) return 'skip';
        const at = rev.current;
        const res = await action<BuilderAutosaveResult>('server:builder:autosave', {
            id: idRef.current,
            definition: d,
        });
        if (!mounted.current) return res.ok ? 'ok' : 'error';
        if (res.ok && res.data) {
            setSavedAt(res.data.savedAt);
            if (res.data.lock) setLock(res.data.lock);
            setRecord(r =>
                r ? { ...r, draftTested: res.data!.draftTested, draftVersion: res.data!.version, hasDraft: true } : r,
            );
            if (rev.current === at) {
                setDirty(false);
                rememberDraft(idRef.current, d, false);
            }
            return 'ok';
        }
        if (res.error === 'err.builder_locked') {
            setLockLostBy(t('builder.someone'));
            setLock(null);
            void fetchRecord();
        }
        return res.error === 'err.rate_limited' ? 'rate' : 'error';
    }, [fetchRecord]);

    const autosaveNow = useCallback(async (): Promise<boolean> => {
        const r = await autosaveRaw();
        return r !== 'error';
    }, [autosaveRaw]);

    const save = useCallback(
        async (opts?: { quiet?: boolean }): Promise<boolean> => {
            const d = defRef.current;
            if (!d) return false;
            setSaving(true);
            const at = rev.current;
            const res = await action<BuilderSaveResult>('server:builder:save', { id: idRef.current, definition: d });
            if (!mounted.current) return res.ok;
            setSaving(false);
            if (!res.ok || !res.data) {
                toast('error', t(res.error ?? 'err.internal'));
                if (res.error === 'err.builder_locked') {
                    setLockLostBy(t('builder.someone'));
                    setLock(null);
                    void fetchRecord();
                }
                return false;
            }
            const data = res.data;
            setSavedAt(data.savedAt);
            if (data.lock) setLock(data.lock);
            setErrors(Array.isArray(data.errors) ? data.errors : []);
            if (data.previousId && data.id !== data.previousId) {
                renameMission(data.previousId, data.id);
                idRef.current = data.id;
                renamedTo.current = data.id;
                onRenamed(data.id);
            }
            if (rev.current === at) {
                setDirty(false);
                rememberDraft(data.id, { ...d, id: data.id }, false);
            }
            setRecord(r =>
                r
                    ? { ...r, id: data.id, draftTested: data.draftTested, draftVersion: data.version, hasDraft: true }
                    : r,
            );
            if (!opts?.quiet) {
                const n = Array.isArray(data.errors) ? data.errors.length : 0;
                toast(
                    data.valid ? 'success' : 'info',
                    t(data.valid ? 'builder.editor.saved_valid' : 'builder.editor.saved_errors', { n }),
                );
            }
            return true;
        },
        [fetchRecord, onRenamed],
    );

    // Test and publish use the STORED draft: make sure what the builder sees is stored first.
    const flush = useCallback(async (): Promise<string | null> => {
        if (!dirtyRef.current) return idRef.current;
        if (!lockMine()) return null;
        // a never-published draft whose label changed is renamed only by a save: the file is named after the label
        const d = defRef.current;
        const rec = recordRef.current;
        if (
            d &&
            rec &&
            rec.source === 'custom' &&
            !rec.overridesBuiltin &&
            rec.version == null &&
            rec.dbStatus === 'draft' &&
            d.label.trim() !== '' &&
            `custom_${labelSlug(d.label)}` !== idRef.current.replace(/_\d+$/, '')
        )
            return (await save({ quiet: true })) ? idRef.current : null;
        const r = await autosaveRaw();
        if (r === 'ok' || r === 'skip') return idRef.current;
        if (r === 'rate') return (await save({ quiet: true })) ? idRef.current : null;
        return null;
    }, [autosaveRaw, save]);

    const validateNow = useCallback(async (): Promise<BuilderValidateResult | null> => {
        const d = defRef.current;
        if (!d) return null;
        setValidating(true);
        const res = await action<BuilderValidateResult>('server:builder:validate', {
            id: idRef.current,
            definition: d,
        });
        if (!mounted.current) return null;
        setValidating(false);
        if (!res.ok || !res.data) return null;
        setErrors(Array.isArray(res.data.errors) ? res.data.errors : []);
        setArmedServer(typeof res.data.armed === 'number' ? res.data.armed : null);
        return res.data;
    }, []);

    // autosave timer
    useEffect(() => {
        const seconds = Math.max(5, Number(config?.autosaveSeconds) || 30);
        const timer = setInterval(() => {
            if (dirtyRef.current && lockMine()) void autosaveNow();
        }, seconds * 1000);
        return () => clearInterval(timer);
    }, [config?.autosaveSeconds, autosaveNow]);

    // debounced live validation of an editable draft
    useEffect(() => {
        if (!def || readOnly || loading) return;
        const timer = setTimeout(() => void validateNow(), VALIDATE_DELAY_MS);
        return () => clearTimeout(timer);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [def, readOnly, loading]);

    const refresh = useCallback(async () => {
        await fetchRecord();
    }, [fetchRecord]);

    const reload = useCallback(
        async (opts?: { lock?: boolean }) => {
            forgetDraft(idRef.current);
            await load(opts);
        },
        [load],
    );

    const releaseLock = useCallback(async () => {
        if (!lockMine()) return;
        await action('server:builder:unlock', { id: idRef.current });
        if (mounted.current) setLock(null);
    }, []);

    // ---- IN-WORLD TOOLS ----------------------------------------------------
    const beforeTool = async () => {
        if (dirtyRef.current) await autosaveNow();
        const d = defRef.current;
        if (d) rememberDraft(idRef.current, d, dirtyRef.current);
    };

    const run = async (
        name: string,
        payload: object,
        spec: PointSpec,
        location: number,
        kind: 'placement' | 'recording' | 'testdrive',
    ) => {
        if (readOnly) return false;
        setToolBusy(true);
        await beforeTool();
        setTool({ kind, missionId: idRef.current, location, key: spec.key, spec, scope, startedAt: Date.now() });
        const res = await clientAction<{ started: boolean }>(name, payload);
        if (!res.ok) {
            setTool(null);
            if (mounted.current) setToolBusy(false);
            toast('error', t(res.error ?? 'err.internal'));
            return false;
        }
        return true;
    };

    // the builderPlace / builderHere payload of a key, null when the location is gone
    const placePayload = (spec: PointSpec, location: number): BuilderPlaceRequest | null => {
        const d = defRef.current;
        if (!d || !config) return null;
        const loc = d.locations[location - 1];
        if (!loc) return null;
        const isStart = spec.key === 'start';
        const existing = isStart ? (loc.start ? [loc.start.coords] : []) : spec.lists ? [] : pointsOf(loc[spec.key]);
        const otherStarts = d.locations.filter((l, i) => i !== location - 1 && l.start).map(l => l.start!.coords);
        const kind = spec.kind === 'route' ? 'marker' : spec.kind;
        const payload: BuilderPlaceRequest = {
            missionId: idRef.current,
            location,
            key: spec.key,
            kind,
            model: spec.model,
            heading: spec.heading,
            multiple: spec.multiple,
            min: spec.lists ? 2 : spec.min,
            max: spec.max,
            points: existing,
            start: loc.start ? loc.start.coords : null,
            spawn: spec.spawn,
            otherStarts,
            label: spec.lists
                ? t('builder.points.flee_path_n', { n: listsOf(loc[spec.key]).length + 1 })
                : t(spec.labelKey),
            ui,
        };
        if (isStart) {
            // the start-marker range, or exactly the search circle when the mission has a search area
            const [lo, hi, dflt] = startRadiusRange(config, d);
            payload.radius = searchCircleOf(config, d) ? dflt : (loc.start?.radius ?? dflt);
            payload.radiusMin = lo;
            payload.radiusMax = hi;
        } else if (spec.radius) payload.radius = spec.radius;
        if (spec.minGap) payload.minGap = spec.minGap;
        if (spec.ruled) payload.streets = true;
        // armed spawns: the placement tool keeps them outside the start circle plus the margin (as the server does)
        if (spec.armed && loc.start && armedKeepOut(config, d, loc.start.radius) !== null) {
            payload.armed = true;
            payload.startRadius = loc.start.radius;
        }
        return payload;
    };

    const place = async (spec: PointSpec, location: number) => {
        const payload = placePayload(spec, location);
        if (!payload) return false;
        return run('builderPlace', payload, spec, location, 'placement');
    };

    // a changed definition from a tool answer or the point list: kept, remembered and stored at once
    const commitNow = async (next: BuilderDefinition, before: BuilderDefinition) => {
        syncStartRadius(next, config, before);
        rev.current += 1;
        defRef.current = next;
        dirtyRef.current = true;
        setDef(next);
        setDirty(true);
        rememberDraft(idRef.current, next, true);
        await autosaveNow();
    };

    const here = async (
        spec: PointSpec,
        location: number,
        index?: number,
        onReply?: (reply: BuilderHereReply) => void,
    ) => {
        if (readOnly) return false;
        const payload = placePayload(spec, location);
        if (!payload) return false;
        const replacing = spec.multiple && index !== undefined && index >= 1 && index <= payload.points.length;
        if (replacing) payload.points = pointsWithout(payload.points, index);
        setToolBusy(true);
        const res = await clientAction<BuilderHereReply>('builderHere', payload);
        if (!mounted.current) return false;
        setToolBusy(false);
        if (!res.ok || !res.data) {
            toast('error', t(res.error ?? 'err.internal'));
            return false;
        }
        const reply = res.data;
        const before = defRef.current;
        if (!reply.ok || !reply.result || !before) {
            toast('warning', t('builder.loc.here_refused', { reason: reply.reason || t('err.internal') }));
            return false;
        }
        const result = replacing ? resultReplacing(reply.result, index) : reply.result;
        const applied = applyResult(before, result, spec, config);
        toast(applied.tone, t(applied.messageKey, applied.vars));
        if (!applied.def) return false;
        await commitNow(applied.def, before);
        onReply?.(reply);
        return true;
    };

    const autoFill = async (spec: PointSpec, location: number, count: number, drop?: number[]) => {
        if (readOnly) return null;
        const base = placePayload(spec, location);
        if (!base) return null;
        if (drop && drop.length) base.points = base.points.filter((_, i) => !drop.includes(i + 1));
        const payload: BuilderAutoPointsRequest = { ...base, count };
        setToolBusy(true);
        const res = await clientAction<BuilderAutoPointsReply>('builderAutoPoints', payload);
        if (!mounted.current) return null;
        setToolBusy(false);
        if (!res.ok || !res.data) {
            toast('error', t(res.error ?? 'err.internal'));
            return null;
        }
        if (!res.data.ok || !res.data.result) {
            toast('warning', res.data.reason || t('err.internal'));
            return null;
        }
        if (res.data.reason) toast('info', res.data.reason);
        return res.data;
    };

    const keepFill = async (spec: PointSpec, result: BuilderClientResultEx) => {
        const before = defRef.current;
        if (readOnly || !before) return false;
        const applied = applyResult(before, result, spec, config);
        toast(applied.tone, t(applied.messageKey, applied.vars));
        if (!applied.def) return false;
        await commitNow(applied.def, before);
        return true;
    };

    const moveLocation = async (location: number, specs: PointSpec[]): Promise<MoveReport | null> => {
        const first = defRef.current;
        const old = first?.locations[location - 1]?.start;
        if (readOnly || !first || !old) {
            if (!old) toast('warning', t('builder.loc.move_start_first'));
            return null;
        }
        const startPayload = placePayload(START_SPEC, location);
        if (!startPayload) return null;
        setToolBusy(true);
        try {
            // 1. the start where the player stands, checked as "Set start here" checks it
            const here = await clientAction<BuilderHereReply>('builderHere', startPayload);
            if (!mounted.current) return null;
            if (!here.ok || !here.data) {
                toast('error', t(here.error ?? 'err.internal'));
                return null;
            }
            if (!here.data.ok || !here.data.result) {
                toast('warning', t('builder.loc.here_refused', { reason: here.data.reason || t('err.internal') }));
                return null;
            }
            const now = here.data.point;
            const offset = { x: now.x - old.coords.x, y: now.y - old.coords.y, z: now.z - old.coords.z };
            // 2. every point list moves by the same offset; Lua puts each point on the ground and checks it again
            const before = defRef.current ?? first;
            const loc = before.locations[location - 1];
            if (!loc) return null;
            const keys: BuilderCheckPointsKey[] = [];
            for (const key of Object.keys(loc)) {
                if (key === 'label' || key === 'start') continue;
                const value = loc[key];
                const points = vecsOf(value);
                if (!points.length) continue;
                const spec = specs.find(s => s.key === key);
                const route = !spec || spec.kind === 'route' || !!spec.lists || isRoute(value);
                const k: BuilderCheckPointsKey = { key, points, route };
                if (spec && !route) {
                    k.kind = spec.kind === 'route' ? 'marker' : spec.kind;
                    if (spec.model) k.model = spec.model;
                    k.spawn = spec.spawn;
                    if (spec.armed) k.armed = true;
                    if (spec.minGap) k.minGap = spec.minGap;
                }
                keys.push(k);
            }
            const req: BuilderCheckPointsRequest = {
                missionId: idRef.current,
                location,
                ui,
                start: { x: now.x, y: now.y, z: now.z },
                startRadius: startPayload.radius ?? old.radius,
                offset,
                keys,
            };
            const res = await clientAction<BuilderCheckPointsReply>('builderCheckPoints', req);
            if (!mounted.current) return null;
            if (!res.ok || !res.data) {
                toast('error', t(res.error ?? 'err.internal'));
                return null;
            }
            if (!res.data.ok) {
                toast('warning', res.data.reason || t('err.internal'));
                return null;
            }
            // 3. the new start, the moved points, one autosave
            const cur = defRef.current ?? before;
            const applied = applyResult(cur, here.data.result, START_SPEC, config);
            if (!applied.def) {
                toast(applied.tone, t(applied.messageKey, applied.vars));
                return null;
            }
            const next = applied.def;
            const nloc = next.locations[location - 1];
            const report: MoveReport = {
                location,
                start: { x: now.x, y: now.y, z: now.z },
                dist: 0,
                moved: res.data.moved,
                failed: [],
                routes: [],
            };
            for (const k of res.data.keys) {
                const refs = nloc ? vecsOf(nloc[k.key]) : [];
                k.points.forEach((p, i) => {
                    const r = refs[i];
                    if (!r) return;
                    r.x = p.x;
                    r.y = p.y;
                    r.z = p.z;
                });
                if (routeMetaOf(idRef.current, location, k.key)) setRouteMeta(idRef.current, location, k.key, null);
                if (!k.checked) report.routes.push(k.key);
                if (k.failed.length) report.failed.push({ key: k.key, points: k.failed });
            }
            report.dist = Math.round(Math.hypot(offset.x, offset.y));
            await commitNow(next, cur);
            return report;
        } finally {
            if (mounted.current) setToolBusy(false);
        }
    };

    const removePoint = async (key: string, location: number, index: number) => {
        const before = defRef.current;
        if (readOnly || !before || !before.locations[location - 1]) return false;
        const next = clone(before);
        if (!removePointAt(next.locations[location - 1], key, index)) return false;
        // a test drive's findings no longer match the points
        if (routeMetaOf(idRef.current, location, key)) setRouteMeta(idRef.current, location, key, null);
        await commitNow(next, before);
        return true;
    };

    const recordRoute = async (spec: PointSpec, location: number) => {
        const payload: BuilderRecordRequest = {
            missionId: idRef.current,
            location,
            key: spec.key,
            stops: !!spec.stops,
            loop: !!spec.loop,
            label: t(spec.labelKey),
            ui,
        };
        return run('builderRecord', payload, spec, location, 'recording');
    };

    const testDrive = async (spec: PointSpec, location: number) => {
        const d = defRef.current;
        const value = d?.locations[location - 1]?.[spec.key];
        if (!isRoute(value) || value.points.length < 2) return false;
        const payload: BuilderTestDriveRequest = {
            missionId: idRef.current,
            location,
            key: spec.key,
            route: { points: value.points, stops: value.stops ?? [] },
            vehicle: spec.vehicle ?? 'stockade',
            speed: spec.speed ?? 60,
            style: spec.style ?? 'normal',
            label: t(spec.labelKey),
            ui,
        };
        if (routeMetaOf(idRef.current, location, spec.key))
            setRouteMeta(idRef.current, location, spec.key, { failed: [] });
        return run('builderTestDrive', payload, spec, location, 'testdrive');
    };

    return {
        id,
        record,
        def,
        loading,
        error,
        readOnly,
        readOnlyReason,
        lock,
        lockLostBy,
        dirty,
        saving,
        savedAt,
        errors,
        armedServer,
        validating,
        toolBusy,
        update,
        save,
        autosaveNow,
        flush,
        reload,
        gone: onGone,
        validateNow,
        refresh,
        takeLock,
        releaseLock,
        place,
        here,
        removePoint,
        autoFill,
        keepFill,
        moveLocation,
        recordRoute,
        testDrive,
    };
}
