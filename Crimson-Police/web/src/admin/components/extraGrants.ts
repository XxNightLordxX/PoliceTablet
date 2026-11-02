// Admin UI -> Permissions -> Extra grants (step G1): Config.Permissions.grants edited one power at a time. Pure
// helpers; ExtraGrantsCard.tsx draws them and saves the whole map as the setting Permissions.grants.

import type { PowerGrant, TeleportGrant } from '../../types/oversight';

export type ExtraGrants = Record<string, PowerGrant>;

// A Qbox citizenid: letters and numbers, at most 16 (the server checks the same).
export const CID_PATTERN = /^[A-Za-z0-9]{1,16}$/;

// How many departments, gangs and characters a power is granted to.
export function grantCount(g: PowerGrant | undefined): number {
    if (!g) return 0;
    return Object.keys(g.departments ?? {}).length + Object.keys(g.gangs ?? {}).length + (g.citizenids ?? []).length;
}

// The grant without its empty parts; undefined when nothing is left.
export function cleanGrant(g: PowerGrant | undefined): PowerGrant | undefined {
    if (!g) return undefined;
    const out: PowerGrant = {};
    if (g.departments && Object.keys(g.departments).length) out.departments = g.departments;
    if (g.gangs && Object.keys(g.gangs).length) out.gangs = g.gangs;
    if (g.citizenids && g.citizenids.length) out.citizenids = g.citizenids;
    return grantCount(out) > 0 ? out : undefined;
}

// The whole map with one power's grant replaced (a power left with nothing is removed).
export function withPower(all: ExtraGrants | undefined, power: string, next: PowerGrant | undefined): ExtraGrants {
    const out: ExtraGrants = {};
    for (const [k, v] of Object.entries(all ?? {})) if (k !== power) out[k] = v;
    const clean = cleanGrant(next);
    if (clean) out[power] = clean;
    return out;
}

// One department's or gang's grade rule set (undefined removes it).
export function withRule(
    g: PowerGrant | undefined,
    part: 'departments' | 'gangs',
    key: string,
    rule: TeleportGrant | undefined,
): PowerGrant {
    const map: Record<string, TeleportGrant> = {};
    for (const [k, v] of Object.entries(g?.[part] ?? {})) if (k !== key) map[k] = v;
    if (rule) map[key] = rule;
    return { ...g, [part]: map };
}

// A citizenid added (trimmed, upper case, once) or removed.
export function withCitizenid(g: PowerGrant | undefined, cid: string, add: boolean): PowerGrant {
    const id = cid.trim().toUpperCase();
    const list = (g?.citizenids ?? []).filter(c => c !== id);
    return { ...g, citizenids: add ? [...list, id] : list };
}
