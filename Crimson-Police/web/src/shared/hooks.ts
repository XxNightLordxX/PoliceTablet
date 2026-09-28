// src/shared/hooks.ts · data hooks for screens.
//
//   const { data, loading, error, refetch } = useRequest<Board>('getBoard', { period, filter }, { pushTopic: 'board' });
//   const { run, busy } = useAction();  await run('server:acceptType', 'patrol');
//   const left = useCountdown(view?.remaining ?? null, { paused: view?.paused });
//   usePush('unit', () => refetch());

import { useCallback, useEffect, useRef, useState } from 'react';
import { action, request, useNuiEvent } from './nui';
import { t, type Vars } from './i18n';
import { toast } from './toast';
import type { ApiResult } from './types';

// ── usePush ───────────────────────────────────────────────────────────────────

/** Run `handler(data)` for every `push` message with this topic (null/undefined topic = off). */
export function usePush<T = unknown>(topic: string | null | undefined, handler: (data: T) => void): void {
  const ref = useRef(handler);
  ref.current = handler;
  useNuiEvent('push', (msg) => {
    if (topic && msg.topic === topic) ref.current(msg.data as T);
  });
}

// ── useRequest ────────────────────────────────────────────────────────────────

export interface UseRequestOptions {
  /** Refetch whenever a `push` message with this topic arrives. */
  pushTopic?: string;
  /** Refetch every N ms while mounted. */
  pollMs?: number;
  /** Do not fetch (e.g. until a selection exists). */
  skip?: boolean;
}

export interface UseRequestResult<T> {
  data: T | null;
  loading: boolean;
  /** err.* key of the last failed fetch (data keeps the last good value). */
  error: string | null;
  refetch: () => Promise<ApiResult<T>>;
  /** Replace data locally (optimistic updates). */
  setData: (next: T | null | ((prev: T | null) => T | null)) => void;
}

/**
 * Fetch `request(name, args)` on mount and whenever `args` changes (compared by JSON value).
 * Refetches on push `pushTopic` and every `pollMs`. Old data stays visible while refetching.
 */
export function useRequest<T = unknown>(name: string, args?: unknown, opts: UseRequestOptions = {}): UseRequestResult<T> {
  const argsKey = JSON.stringify(args ?? {});
  const skip = !!opts.skip;
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState<boolean>(!skip);
  const [error, setError] = useState<string | null>(null);
  const seq = useRef(0);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const refetch = useCallback(async (): Promise<ApiResult<T>> => {
    if (skip) return { ok: false, error: 'err.refused' };
    const id = ++seq.current;
    setLoading(true);
    const res = await request<T>(name, JSON.parse(argsKey));
    if (!mounted.current || id !== seq.current) return res;
    if (res.ok) {
      setData((res.data ?? null) as T | null);
      setError(null);
    } else {
      setError(res.error ?? 'err.internal');
    }
    setLoading(false);
    return res;
  }, [name, argsKey, skip]);

  useEffect(() => {
    if (skip) {
      setLoading(false);
      return;
    }
    void refetch();
  }, [refetch, skip]);

  usePush(opts.pushTopic, () => {
    void refetch();
  });

  const pollMs = opts.pollMs ?? 0;
  useEffect(() => {
    if (skip || !pollMs || pollMs < 250) return;
    const id = setInterval(() => void refetch(), pollMs);
    return () => clearInterval(id);
  }, [refetch, pollMs, skip]);

  return { data, loading, error, refetch, setData };
}

// ── useAction ─────────────────────────────────────────────────────────────────

export interface RunOptions {
  /** Locale key of a success toast (none by default). */
  success?: string;
  successVars?: Vars;
  /** Do not toast the error (the caller shows it). */
  silent?: boolean;
}

/**
 * Server actions with a busy flag. A failed action shows an error toast with t(error).
 *   const { run, busy } = useAction();
 *   const res = await run('server:sup:setTypePayout', { type, amount, reason }, { success: 'sup.payout_saved' });
 */
export function useAction(): {
  run: <T = unknown>(name: string, payload?: unknown, opts?: RunOptions) => Promise<ApiResult<T>>;
  busy: boolean;
} {
  const [pending, setPending] = useState(0);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const run = useCallback(async <T = unknown>(name: string, payload?: unknown, opts: RunOptions = {}): Promise<ApiResult<T>> => {
    setPending((n) => n + 1);
    try {
      const res = await action<T>(name, payload);
      if (!res.ok && !opts.silent) toast('error', t(res.error || 'err.internal'));
      else if (res.ok && opts.success) toast('success', t(opts.success, opts.successVars));
      return res;
    } finally {
      if (mounted.current) setPending((n) => Math.max(0, n - 1));
    }
  }, []);

  return { run, busy: pending > 0 };
}

// ── useCountdown ──────────────────────────────────────────────────────────────

export interface CountdownOptions {
  /** Freeze at the current value. */
  paused?: boolean;
  /** Change this to restart from `seconds` even when the number is unchanged (e.g. a new HUD state). */
  resetKey?: unknown;
  onDone?: () => void;
}

/**
 * Counts `seconds` down locally, one step per second, never below 0. Restarts whenever `seconds`
 * (or `resetKey`) changes. Returns null when `seconds` is null.
 */
export function useCountdown(seconds: number | null | undefined, opts: CountdownOptions = {}): number | null {
  const { paused = false, resetKey } = opts;
  const base = seconds === null || seconds === undefined || isNaN(Number(seconds)) ? null : Math.max(0, Math.floor(Number(seconds)));
  const [left, setLeft] = useState<number | null>(base);
  const onDone = useRef(opts.onDone);
  onDone.current = opts.onDone;

  useEffect(() => {
    setLeft(base);
    if (base === null || paused || base <= 0) return;
    const start = Date.now();
    let last = base;
    const id = setInterval(() => {
      const next = Math.max(0, base - Math.floor((Date.now() - start) / 1000));
      if (next !== last) {
        last = next;
        setLeft(next);
        if (next === 0) {
          clearInterval(id);
          onDone.current?.();
        }
      }
    }, 200);
    return () => clearInterval(id);
  }, [base, paused, resetKey]);

  return left;
}

// ── Escape layers ─────────────────────────────────────────────────────────────
// Escape closes the topmost layer (a dialog, a popover); with no layer open it closes the UI.

const layers: { id: number; close: () => void }[] = [];
let layerSeq = 0;

/** Register a layer that Escape closes first (Dialog uses it). */
export function useEscapeLayer(active: boolean, onEscape: () => void): void {
  const ref = useRef(onEscape);
  ref.current = onEscape;
  useEffect(() => {
    if (!active) return;
    const entry = { id: ++layerSeq, close: () => ref.current() };
    layers.push(entry);
    return () => {
      const i = layers.findIndex((l) => l.id === entry.id);
      if (i >= 0) layers.splice(i, 1);
    };
  }, [active]);
}

/** Close the topmost layer. Returns false when no layer was open. */
export function closeTopLayer(): boolean {
  const top = layers[layers.length - 1];
  if (!top) return false;
  top.close();
  return true;
}

// ── Misc ──────────────────────────────────────────────────────────────────────

/** Viewport size, updated on resize. */
export function useViewport(): { width: number; height: number } {
  const get = () => ({ width: window.innerWidth || 1920, height: window.innerHeight || 1080 });
  const [size, setSize] = useState(get);
  useEffect(() => {
    const onResize = () => setSize(get());
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);
  return size;
}

/** Scale for HUD-style elements designed at 1920×1080 (clamped to [min, max]). */
export function useHudScale(min = 0.8, max = 2): number {
  const { width, height } = useViewport();
  return Math.min(max, Math.max(min, Math.min(width / 1920, height / 1080)));
}

/** Previous render's value. */
export function usePrevious<T>(value: T): T | undefined {
  const ref = useRef<T>();
  useEffect(() => {
    ref.current = value;
  }, [value]);
  return ref.current;
}
