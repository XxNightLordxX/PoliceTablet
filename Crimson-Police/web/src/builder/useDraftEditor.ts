// src/builder/useDraftEditor.ts · one open mission in the Mission Builder (docs/notes/builder_protocol.md §2–§6).
//
//   builder:get { id }            → the record; an editable custom mission is locked with server:builder:lock
//   server:builder:autosave       → every Config.Builder.autosaveSeconds while the lock is mine and the draft
//                                   changed (also before a tool closes the tablet and after a tool result)
//   server:builder:save           → explicit save (errors, previousId after a rename of a never-published draft)
//   server:builder:validate       → live guardrails (debounced, publish checks included)
//   server:builder:unlock         → when the editor is closed
//   client actions builderPlace / builderRecord / builderTestDrive (+ builderResult on mount)
//   push 'builder'                → lockBroken / tested / published / … for this mission refetch or go read-only
// The unsaved draft is kept in the module store (store.ts), so closing the tablet for a tool loses nothing.
import { useCallback, useEffect, useRef, useState } from 'react';
import { usePush } from '../shared/hooks';
import { t } from '../shared/i18n';
import { action, clientAction, request } from '../shared/nui';
import { toast } from '../shared/toast';
import type {
  BuilderAutosaveResult, BuilderConfig, BuilderDefinition, BuilderError, BuilderLock, BuilderLockResult, BuilderPush,
  BuilderRecord, BuilderSaveResult, BuilderValidateResult,
} from '../types/builder_server';
import type {
  BuilderClientResultEx, BuilderPlaceRequest, BuilderRecordRequest, BuilderTestDriveRequest, BuilderUi, PointSpec,
} from '../types/builder_client';
import { applyResult } from './applyResult';
import { clone, isRoute, listsOf, normalizeDefinition, pointsOf } from './defUtils';
import { searchCircleOf, startRadiusRange, syncStartRadius } from './schema';
import {
  currentTool, forgetDraft, queueResult, recallDraft, rememberDraft, renameMission, routeMetaOf, setRouteMeta, setTool,
  subscribeBuilder, takeResults, type BuilderScope,
} from './store';

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
  /** store unsaved changes now (autosave; an explicit save when autosave is rate-limited). false = not stored */
  flush: () => Promise<boolean>;
  /** drop the local draft and load the mission again (after publish / discard) */
  reload: () => Promise<void>;
  /** the mission is gone (deleted): close the editor */
  gone: () => void;
  validateNow: () => Promise<BuilderValidateResult | null>;
  refresh: () => Promise<void>;
  takeLock: () => Promise<boolean>;
  releaseLock: () => Promise<void>;
  place: (spec: PointSpec, location: number) => Promise<boolean>;
  recordRoute: (spec: PointSpec, location: number) => Promise<boolean>;
  testDrive: (spec: PointSpec, location: number) => Promise<boolean>;
}

const VALIDATE_DELAY_MS = 1500;
const START_SPEC: PointSpec = {
  key: 'start', field: 'start', labelKey: 'builder.points.start', kind: 'start', heading: false, multiple: false, min: 1, max: 1,
  spawn: false, objective: 0,
};

export function startSpec(): PointSpec {
  return START_SPEC;
}

export function useDraftEditor(id: string, scope: BuilderScope, ui: BuilderUi, config: BuilderConfig | null, onRenamed: (id: string) => void, onGone: () => void): DraftEditor {
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

  // ── load ────────────────────────────────────────────────────────────────────
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
    if (res.error && res.error !== 'err.builder_locked' && res.error !== 'err.builder_read_only') toast('error', t(res.error));
    return false;
  }, []);

  const applyPending = useCallback(async () => {
    // pull the Lua copy too (a push may have been missed); both are deduplicated by seq
    const pulled = await clientAction<BuilderClientResultEx | null>('builderResult', {});
    if (pulled.ok && pulled.data) queueResult(pulled.data);
    const list = takeResults(idRef.current);
    if (!list.length) return;
    let next = defRef.current;
    if (!next) return;
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

  const load = useCallback(async () => {
    setLoading(true);
    const rec = await fetchRecord();
    if (!rec) {
      setLoading(false);
      return;
    }
    const memory = recallDraft(rec.id);
    const base = memory && memory.dirty ? memory.def : rec.definition;
    const d = normalizeDefinition(base);
    // a draft saved before the search-circle rule (start radius from the 20–150 m range): an editable one gets its
    // start radii put on the search circle at once, as a pending change, so the locked field shows what is saved
    const editable = rec.source === 'custom' && rec.can.edit && rec.dbStatus !== 'archived' && !(rec.lock && !rec.lock.mine);
    const synced = editable && syncStartRadius(d, configRef.current);
    setDef(d);
    setDirty(!!(memory && memory.dirty) || synced);
    if (synced) rememberDraft(rec.id, d, true);
    setErrors(Array.isArray(rec.errors) ? rec.errors : []);
    setArmedServer(typeof rec.armed === 'number' ? rec.armed : null);
    setLockLostBy(null);
    if (rec.source === 'custom' && rec.can.edit && rec.dbStatus !== 'archived' && !(rec.lock && !rec.lock.mine)) {
      await takeLock();
    } else {
      setLock(rec.lock && rec.lock.mine ? rec.lock : null);
    }
    if (!mounted.current) return;
    setLoading(false);
    await applyPending();
  }, [fetchRecord, takeLock, applyPending]);

  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  // results that arrive while the editor is open
  useEffect(() => subscribeBuilder(() => {
    if (!loading && defRef.current) {
      const tool = currentTool();
      setToolBusy(!!tool && tool.missionId === idRef.current);
    }
  }), [loading]);
  usePush<BuilderPush>('builder', (data) => {
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
        void fetchRecord().then((rec) => {
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

  // ── edit ────────────────────────────────────────────────────────────────────
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
    const res = await action<BuilderAutosaveResult>('server:builder:autosave', { id: idRef.current, definition: d });
    if (!mounted.current) return res.ok ? 'ok' : 'error';
    if (res.ok && res.data) {
      setSavedAt(res.data.savedAt);
      if (res.data.lock) setLock(res.data.lock);
      setRecord((r) => (r ? { ...r, draftTested: res.data!.draftTested, draftVersion: res.data!.version, hasDraft: true } : r));
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

  const save = useCallback(async (opts?: { quiet?: boolean }): Promise<boolean> => {
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
      onRenamed(data.id);
    }
    if (rev.current === at) {
      setDirty(false);
      rememberDraft(data.id, { ...d, id: data.id }, false);
    }
    setRecord((r) => (r ? { ...r, id: data.id, draftTested: data.draftTested, draftVersion: data.version, hasDraft: true } : r));
    if (!opts?.quiet) {
      const n = Array.isArray(data.errors) ? data.errors.length : 0;
      toast(data.valid ? 'success' : 'info', t(data.valid ? 'builder.editor.saved_valid' : 'builder.editor.saved_errors', { n }));
    }
    return true;
  }, [fetchRecord, onRenamed]);

  // Test and publish use the STORED draft: make sure what the builder sees is stored first.
  const flush = useCallback(async (): Promise<boolean> => {
    if (!dirtyRef.current) return true;
    if (!lockMine()) return false;
    const r = await autosaveRaw();
    if (r === 'ok' || r === 'skip') return true;
    if (r === 'rate') return save({ quiet: true });
    return false;
  }, [autosaveRaw, save]);

  const validateNow = useCallback(async (): Promise<BuilderValidateResult | null> => {
    const d = defRef.current;
    if (!d) return null;
    setValidating(true);
    const res = await action<BuilderValidateResult>('server:builder:validate', { id: idRef.current, definition: d });
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

  const reload = useCallback(async () => {
    forgetDraft(idRef.current);
    await load();
  }, [load]);

  const releaseLock = useCallback(async () => {
    if (!lockMine()) return;
    await action('server:builder:unlock', { id: idRef.current });
    if (mounted.current) setLock(null);
  }, []);

  // ── in-world tools ─────────────────────────────────────────────────────────
  const beforeTool = async () => {
    if (dirtyRef.current) await autosaveNow();
    const d = defRef.current;
    if (d) rememberDraft(idRef.current, d, dirtyRef.current);
  };

  const run = async (name: string, payload: object, spec: PointSpec, location: number, kind: 'placement' | 'recording' | 'testdrive') => {
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

  const place = async (spec: PointSpec, location: number) => {
    const d = defRef.current;
    if (!d || !config) return false;
    const loc = d.locations[location - 1];
    if (!loc) return false;
    const isStart = spec.key === 'start';
    const existing = isStart ? (loc.start ? [loc.start.coords] : []) : spec.lists ? [] : pointsOf(loc[spec.key]);
    const otherStarts = d.locations.filter((l, i) => i !== location - 1 && l.start).map((l) => l.start!.coords);
    const kind = spec.kind === 'route' ? 'marker' : spec.kind;
    const payload: BuilderPlaceRequest = {
      missionId: idRef.current, location, key: spec.key, kind, model: spec.model, heading: spec.heading, multiple: spec.multiple,
      min: spec.lists ? 2 : spec.min, max: spec.max, points: existing,
      start: loc.start ? loc.start.coords : null, spawn: spec.spawn, otherStarts,
      label: spec.lists ? t('builder.points.flee_path_n', { n: listsOf(loc[spec.key]).length + 1 }) : t(spec.labelKey),
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
    return run('builderPlace', payload, spec, location, 'placement');
  };

  const recordRoute = async (spec: PointSpec, location: number) => {
    const payload: BuilderRecordRequest = {
      missionId: idRef.current, location, key: spec.key, stops: !!spec.stops, loop: !!spec.loop, label: t(spec.labelKey), ui,
    };
    return run('builderRecord', payload, spec, location, 'recording');
  };

  const testDrive = async (spec: PointSpec, location: number) => {
    const d = defRef.current;
    const value = d?.locations[location - 1]?.[spec.key];
    if (!isRoute(value) || value.points.length < 2) return false;
    const payload: BuilderTestDriveRequest = {
      missionId: idRef.current, location, key: spec.key, route: { points: value.points, stops: value.stops ?? [] },
      vehicle: spec.vehicle ?? 'stockade', speed: spec.speed ?? 60, style: spec.style ?? 'normal', label: t(spec.labelKey), ui,
    };
    if (routeMetaOf(idRef.current, location, spec.key)) setRouteMeta(idRef.current, location, spec.key, { failed: [] });
    return run('builderTestDrive', payload, spec, location, 'testdrive');
  };

  return {
    id, record, def, loading, error, readOnly, readOnlyReason, lock, lockLostBy, dirty, saving, savedAt, errors, armedServer,
    validating, toolBusy, update, save, autosaveNow, flush, reload, gone: onGone, validateNow, refresh, takeLock, releaseLock,
    place, recordRoute, testDrive,
  };
}
