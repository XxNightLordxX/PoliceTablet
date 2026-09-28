// src/builder/useBuilderConfig.ts · builder:config (Config.Blocks ranges, allowed lists, limits and the
// caller's builder permissions), fetched once per open UI and shared by every builder component.
import { useEffect, useState } from 'react';
import { request } from '../shared/nui';
import type { BuilderConfig } from '../types/builder_server';

let cached: { key: string; data: BuilderConfig } | null = null;
let inflight: { key: string; promise: Promise<{ data: BuilderConfig | null; error: string | null }> } | null = null;

function load(key: string) {
  if (inflight && inflight.key === key) return inflight.promise;
  const promise = request<BuilderConfig>('builder:config', {}).then((res) => {
    inflight = null;
    if (res.ok && res.data) {
      cached = { key, data: res.data };
      return { data: res.data, error: null };
    }
    return { data: null, error: res.error ?? 'err.internal' };
  });
  inflight = { key, promise };
  return promise;
}

/** `scope` ('sup' | 'admin') keys the cache: admins get every permission, supervisors their own. */
export function useBuilderConfig(scope: string): { config: BuilderConfig | null; error: string | null; retry: () => void } {
  const [config, setConfig] = useState<BuilderConfig | null>(cached && cached.key === scope ? cached.data : null);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let alive = true;
    if (cached && cached.key === scope && attempt === 0) {
      setConfig(cached.data);
      return undefined;
    }
    void load(scope).then((r) => {
      if (!alive) return;
      setConfig(r.data);
      setError(r.error);
    });
    return () => {
      alive = false;
    };
  }, [scope, attempt]);
  return {
    config,
    error,
    retry: () => {
      cached = null;
      setError(null);
      setAttempt((n) => n + 1);
    },
  };
}
