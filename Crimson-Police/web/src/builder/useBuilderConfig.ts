// builder:config (Config.Blocks ranges, allowed lists, limits and the caller's builder permissions), fetched once per
// open UI and shared by every builder component.

import { useEffect, useState } from 'react';
import { asArray } from '../shared/data';
import { request } from '../shared/nui';
import type { BuilderConfig } from '../types/builder_server';

let cached: { key: string; data: BuilderConfig } | null = null;
let inflight: { key: string; promise: Promise<{ data: BuilderConfig | null; error: string | null }> } | null = null;

function triple(v: unknown, fb: [number, number, number]): [number, number, number] {
    const a = asArray(v as number[]);
    return typeof a[0] === 'number' && typeof a[1] === 'number'
        ? [a[0], a[1], typeof a[2] === 'number' ? a[2] : fb[2]]
        : fb;
}

// builder:config with every list as an array (exported for the tests of the screens).
export function normalizeConfig(raw: BuilderConfig): BuilderConfig {
    const c = (raw ?? {}) as BuilderConfig;
    const allowed = (c.allowed ?? {}) as Partial<BuilderConfig['allowed']>;
    const map = <T>(v: unknown): Record<string, T> =>
        v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, T>) : {};
    const lists = (v: unknown): Record<string, string[]> => {
        const out: Record<string, string[]> = {};
        Object.entries(map<unknown>(v)).forEach(([k, l]) => {
            out[k] = asArray(l as string[]);
        });
        return out;
    };
    return {
        ...c,
        blocks: map<Record<string, unknown>>(c.blocks),
        blockList: asArray(c.blockList),
        allowed: {
            weapons: asArray(allowed.weapons),
            peds: asArray(allowed.peds),
            vehicles: asArray(allowed.vehicles),
            escortVehicles: asArray(allowed.escortVehicles),
            animations: asArray(allowed.animations),
        },
        bonuses: asArray(c.bonuses).map(b => ({ ...b, block: b.block ?? null, each: !!b.each, penalty: !!b.penalty })),
        noBuildZones: asArray(c.noBuildZones).filter(z => z && z.coords && typeof z.coords.x === 'number'),
        departments: asArray(c.departments),
        missionTypes: asArray(c.missionTypes),
        tiers: asArray(c.tiers),
        startRadius: triple(c.startRadius, [20, 150, 60]),
        itemCount: triple(c.itemCount, [1, 100, 1]).slice(0, 2) as [number, number],
        percentFields: lists(c.percentFields),
        secondsFields: lists(c.secondsFields),
        spawnFields: lists(c.spawnFields),
        forbiddenItems: asArray(c.forbiddenItems),
        permissions: map<boolean>(c.permissions) as BuilderConfig['permissions'],
    };
}

function load(key: string) {
    if (inflight && inflight.key === key) return inflight.promise;
    const promise = request<BuilderConfig>('builder:config', {}).then(res => {
        inflight = null;
        if (res.ok && res.data) {
            const data = normalizeConfig(res.data);
            cached = { key, data };
            return { data, error: null };
        }
        return { data: null, error: res.error ?? 'err.internal' };
    });
    inflight = { key, promise };
    return promise;
}

// `scope` ('sup' | 'admin') keys the cache: admins get every permission, supervisors their own.
export function useBuilderConfig(scope: string): {
    config: BuilderConfig | null;
    error: string | null;
    retry: () => void;
} {
    const [config, setConfig] = useState<BuilderConfig | null>(cached && cached.key === scope ? cached.data : null);
    const [error, setError] = useState<string | null>(null);
    const [attempt, setAttempt] = useState(0);
    useEffect(() => {
        let alive = true;
        if (cached && cached.key === scope && attempt === 0) {
            setConfig(cached.data);
            return undefined;
        }
        void load(scope).then(r => {
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
            setAttempt(n => n + 1);
        },
    };
}
