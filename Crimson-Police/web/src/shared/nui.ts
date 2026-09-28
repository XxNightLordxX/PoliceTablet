// src/shared/nui.ts · the NUI bridge (docs/ARCHITECTURE.md §9.1).
//
//   Lua → NUI: window 'message' events whose data.type is one of
//              open | close | session | notify | hud | result | push | overlay | theme
//   NUI → Lua: POST https://<resource>/<endpoint> with a JSON body, endpoints
//              ready | close | request | action | client | switchUi
//
// In a normal browser (isEnvBrowser()) nothing is POSTed: request/action/client calls are answered
// by mocks registered with registerMock() (see src/mocks/*.mock.ts), and emitDebug() fakes Lua
// messages. Every call resolves (never rejects) to { ok, data?, error? } where error is an err.* key.

import { useEffect, useRef } from 'react';
import type { ApiResult, NuiEndpoint, NuiMessageMap, NuiMessageType } from './types';

declare global {
  interface Window {
    GetParentResourceName?: () => string;
    invokeNative?: unknown;
  }
}

const FALLBACK_RESOURCE = 'Crimson-Police';
const TIMEOUT_MS = 20000;
const MOCK_LATENCY_MS = 120;

/** True in a normal browser (dev mode), false inside FiveM's CEF. */
export function isEnvBrowser(): boolean {
  return typeof window === 'undefined' || !window.invokeNative;
}

/** The resource name used in NUI callback URLs. */
export function resourceName(): string {
  try {
    if (typeof window !== 'undefined' && typeof window.GetParentResourceName === 'function') {
      const name = window.GetParentResourceName();
      if (name) return name;
    }
  } catch {
    /* fall through */
  }
  return FALLBACK_RESOURCE;
}

// ── Mocks (browser mode only) ─────────────────────────────────────────────────

export type MockKind = 'request' | 'action' | 'client';
/** A mock receives the args/payload and returns the data (or a Promise of it).
 *  Throw an Error whose message is an err.* key to answer { ok: false, error }. */
export type MockFn = (payload: any) => unknown;

interface MockEntry { fn: MockFn; fallback: boolean }
const mocks: Record<MockKind, Map<string, MockEntry>> = {
  request: new Map(),
  action: new Map(),
  client: new Map(),
};

/**
 * Register a browser-mode answer for request(name) / action(name) / clientAction(name).
 * `opts.fallback` registers a default that any normal registration overrides regardless of
 * load order (core.mock.ts uses it for data other feature mocks may define properly).
 */
export function registerMock(kind: MockKind, name: string, fn: MockFn, opts: { fallback?: boolean } = {}): void {
  const table = mocks[kind];
  const existing = table.get(name);
  const fallback = !!opts.fallback;
  if (existing) {
    if (fallback && !existing.fallback) return;          // never replace a real mock with a fallback
    if (!fallback && !existing.fallback) console.warn(`[crimson-police:mock] ${kind} "${name}" registered twice; the later one wins`);
  }
  table.set(name, { fn, fallback });
}

/** Names of every registered mock (for the dev panel). */
export function listMocks(): Record<MockKind, string[]> {
  return {
    request: [...mocks.request.keys()].sort(),
    action: [...mocks.action.keys()].sort(),
    client: [...mocks.client.keys()].sort(),
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorKey(e: unknown): string {
  const msg = e instanceof Error ? e.message : typeof e === 'string' ? e : '';
  return msg && msg.startsWith('err.') ? msg : 'err.internal';
}

async function runMock<T>(kind: MockKind, name: string, payload: unknown): Promise<ApiResult<T>> {
  const entry = mocks[kind].get(name);
  await sleep(MOCK_LATENCY_MS);
  if (!entry) {
    console.warn(`[crimson-police:mock] no ${kind} mock for "${name}" (add one in src/mocks/<feature>.mock.ts)`);
    return { ok: false, error: 'err.no_response' };
  }
  try {
    const data = (await entry.fn(payload)) as T;
    return { ok: true, data };
  } catch (e) {
    return { ok: false, error: errorKey(e) };
  }
}

async function mockEndpoint<T>(endpoint: string, body: any): Promise<ApiResult<T>> {
  switch (endpoint) {
    case 'request':
      return runMock<T>('request', String(body?.name), body?.args ?? {});
    case 'action':
      return runMock<T>('action', String(body?.name), body?.payload);
    case 'client':
      return runMock<T>('client', String(body?.name), body?.payload);
    case 'switchUi':
      // Browser mode: switching UI = building the session for that UI.
      return runMock<T>('request', 'getSession', { ui: body?.ui });
    default:
      return { ok: true } as ApiResult<T>;          // ready, close, anything else
  }
}

// ── Transport ─────────────────────────────────────────────────────────────────

function normalise<T>(json: unknown): ApiResult<T> {
  if (json && typeof json === 'object' && typeof (json as ApiResult<T>).ok === 'boolean') {
    const r = json as ApiResult<T>;
    return r.ok ? { ok: true, data: r.data } : { ok: false, error: r.error || 'err.refused', data: r.data };
  }
  // A bare value (a callback that replied with plain data) counts as success.
  return { ok: true, data: json as T };
}

/** POST to https://<resource>/<endpoint>. Never rejects. */
export async function fetchNui<T = unknown>(endpoint: NuiEndpoint | string, body: unknown = {}): Promise<ApiResult<T>> {
  if (isEnvBrowser()) return mockEndpoint<T>(endpoint, body);

  const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timer = setTimeout(() => controller?.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`https://${resourceName()}/${endpoint}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(body ?? {}),
      signal: controller?.signal,
    });
    const text = await res.text();
    if (!text) return { ok: false, error: 'err.no_response' };
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      return { ok: false, error: 'err.internal' };
    }
    return normalise<T>(json);
  } catch (e) {
    const aborted = (e as { name?: string })?.name === 'AbortError';
    return { ok: false, error: aborted ? 'err.timeout' : 'err.no_response' };
  } finally {
    clearTimeout(timer);
  }
}

/** Read data: ox_lib callback `crimson-police:<name>` (e.g. 'getBoard', 'sup:getLiveRuns'). */
export function request<T = unknown>(name: string, args: unknown = {}): Promise<ApiResult<T>> {
  return fetchNui<T>('request', { name, args: args ?? {} });
}

/** Write action: net event `crimson-police:<name>` (name like 'server:acceptType', 'server:sup:setTypePayout'). */
export function action<T = unknown>(name: string, payload?: unknown): Promise<ApiResult<T>> {
  return fetchNui<T>('action', { name, payload: payload === undefined ? null : payload });
}

/** Client-local action registered with CP.Tablet.registerClientAction (e.g. 'setGps', 'logoFailed'). */
export function clientAction<T = unknown>(name: string, payload?: unknown): Promise<ApiResult<T>> {
  return fetchNui<T>('client', { name, payload: payload === undefined ? null : payload });
}

// ── Lua → NUI messages ────────────────────────────────────────────────────────

type AnyHandler = (msg: any) => void;

/**
 * Subscribe to Lua messages of one `type`. The handler receives the whole message object,
 * e.g. useNuiEvent('hud', (m) => setHud(m.hud)). The latest handler is always used, so it may
 * close over state without re-subscribing.
 */
export function useNuiEvent<K extends NuiMessageType>(type: K, handler: (msg: NuiMessageMap[K]) => void): void;
export function useNuiEvent(type: string, handler: AnyHandler): void;
export function useNuiEvent(type: string, handler: AnyHandler): void {
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => {
    const listener = (event: MessageEvent) => {
      const data = event.data;
      if (!data || typeof data !== 'object' || data.type !== type) return;
      ref.current(data);
    };
    window.addEventListener('message', listener);
    return () => window.removeEventListener('message', listener);
  }, [type]);
}

/**
 * Browser mode only: dispatch a fake Lua message, e.g.
 *   emitDebug('hud', { hud: sampleHud() })
 *   emitDebug('push', { topic: 'run', data: null })
 * `delay` (ms) defers it. Does nothing inside FiveM.
 */
export function emitDebug<K extends NuiMessageType>(type: K, data?: Omit<NuiMessageMap[K], 'type'>, delay?: number): void;
export function emitDebug(type: string, data?: Record<string, unknown>, delay?: number): void;
export function emitDebug(type: string, data: Record<string, unknown> = {}, delay = 0): void {
  if (!isEnvBrowser()) return;
  const fire = () => window.dispatchEvent(new MessageEvent('message', { data: { ...data, type } }));
  if (delay > 0) setTimeout(fire, delay);
  else fire();
}
