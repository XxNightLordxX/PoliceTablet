// The Mission Builder's knowledge of the nine objective blocks: defaults of a new

import { asArray } from '../shared/data';
import type { IconName } from '../shared/components';
import type { BuilderConfig, BuilderDefinition, BuilderObjective } from '../types/builder_server';
import type { PointSpec } from '../types/builder_client';
import { getAt } from './defUtils';

export type Rng = { min: number; max: number; def: number };

// Per-location spot counts the blocks require for custom missions but keep as local constants.
export const SEARCH_MIN_SPOTS = 6; // blocks/search_area MIN_SPOTS
export const SHARED_DEVICES = 'shared:devices';
export const HOSTILE_BELOW = 0.25; // hostile_waves surrender.belowHealth default
const MAX_SPOTS = 40;

export const BLOCK_ICONS: Record<string, IconName> = {
    hostile_waves: 'target',
    escort: 'shield',
    pursuit: 'car',
    checkpoint_route: 'flag',
    interact_points: 'mapPin',
    skill_check: 'zap',
    protect_rescue: 'users',
    flee_arrest: 'user',
    search_area: 'search',
};

// ============================================================================
//                                CONFIG READERS
// ============================================================================

export function blockCfg(cfg: BuilderConfig, block: string): Record<string, unknown> {
    return (cfg.blocks?.[block] ?? {}) as Record<string, unknown>;
}

// { min, max, def } of a [min, max, default] (or [min, max]) config entry.
export function rangeOf(cfg: BuilderConfig, block: string, key: string, fallback?: [number, number, number]): Rng {
    const v = blockCfg(cfg, block)[key];
    if (Array.isArray(v) && v.length >= 2 && typeof v[0] === 'number' && typeof v[1] === 'number') {
        const def = typeof v[2] === 'number' ? v[2] : v[0];
        return { min: v[0], max: v[1], def };
    }
    const f = fallback ?? [0, 100, 0];
    return { min: f[0], max: f[1], def: f[2] };
}

export function optionsOf(cfg: BuilderConfig, block: string, key: string): { options: string[]; def: unknown } {
    const v = blockCfg(cfg, block)[key] as { options?: unknown; default?: unknown } | undefined;
    return { options: asArray(v?.options as string[]).filter(o => typeof o === 'string'), def: v?.default };
}

export function flagOf(cfg: BuilderConfig, block: string, key: string, fallback = false): boolean {
    const v = blockCfg(cfg, block)[key] as { default?: unknown } | undefined;
    return typeof v?.default === 'boolean' ? v.default : fallback;
}

export function listOf(cfg: BuilderConfig, block: string, key: string): string[] {
    const v = blockCfg(cfg, block)[key];
    return asArray(v as string[]).filter(s => typeof s === 'string');
}

export function numOf(cfg: BuilderConfig, block: string, key: string, fallback: number): number {
    const v = blockCfg(cfg, block)[key];
    return typeof v === 'number' ? v : fallback;
}

export function strOf(cfg: BuilderConfig, block: string, key: string, fallback: string): string {
    const v = blockCfg(cfg, block)[key];
    return typeof v === 'string' ? v : fallback;
}

export function detailRange(cfg: BuilderConfig, key: string, fallback: [number, number, number]): Rng {
    return rangeOf(cfg, 'details', key, fallback);
}

export function blockMinSeconds(cfg: BuilderConfig, block: string): number {
    const entry = asArray(cfg.blockList).find(b => b.id === block);
    return entry && typeof entry.minSeconds === 'number' && entry.minSeconds > 0 ? entry.minSeconds : 30;
}

export function presenceOf(cfg: BuilderConfig, block: string): Rng {
    return rangeOf(cfg, block, 'presenceRange', [50, 800, 150]);
}

// ============================================================================
//                                 START RADIUS
// ============================================================================
// Mirrors modules/builder/server.lua (B.validate): the start marker of a mission with a search_area objective
// is its search circle (the run starts when a participant enters it), so every location's start radius must
// equal the FIRST search_area objective's startRadius (its block default when unset) and is checked against
// Config.Blocks.search_area.startRadius instead of the start-marker range (builder:config startRadius).

export interface SearchCircle {
    // 1-based objective index
    objective: number;
    radius: number;
    range: Rng;
}

export function searchCircleOf(cfg: BuilderConfig, def: BuilderDefinition | null | undefined): SearchCircle | null {
    const list = asArray(def?.objectives);
    const i = list.findIndex(o => o && o.block === 'search_area');
    if (i < 0) return null;
    const range = rangeOf(cfg, 'search_area', 'startRadius', [200, 1000, 600]);
    const v = list[i].startRadius;
    return { objective: i + 1, radius: typeof v === 'number' && Number.isFinite(v) ? v : range.def, range };
}

// [min, max, default] a start radius may take in this mission (the search circle: exactly its radius).
export function startRadiusRange(
    cfg: BuilderConfig | null | undefined,
    def: BuilderDefinition | null | undefined,
): [number, number, number] {
    const marker: [number, number, number] = cfg?.startRadius ?? [20, 150, 60];
    if (!cfg) return marker;
    const sc = searchCircleOf(cfg, def);
    return sc ? [sc.radius, sc.radius, sc.radius] : marker;
}

// Keeps every placed start radius in line with the mission (changes def in place): all of them equal the search
// circle when there is one; when the search area was removed (prev had one), radii outside the start-marker
// range go back to its default. Returns true when something changed.
export function syncStartRadius(
    def: BuilderDefinition,
    cfg: BuilderConfig | null | undefined,
    prev?: BuilderDefinition | null,
): boolean {
    if (!cfg) return false;
    let changed = false;
    const sc = searchCircleOf(cfg, def);
    const [lo, hi, dflt] = cfg.startRadius ?? [20, 150, 60];
    const hadSearch = !!prev && !!searchCircleOf(cfg, prev);
    asArray(def.locations).forEach(l => {
        const s = l && l.start;
        if (!s) return;
        if (sc) {
            if (s.radius !== sc.radius) {
                s.radius = sc.radius;
                changed = true;
            }
        } else if (hadSearch && !(typeof s.radius === 'number' && s.radius >= lo && s.radius <= hi)) {
            s.radius = dflt;
            changed = true;
        }
    });
    return changed;
}

// ============================================================================
//                                LOCATION KEYS
// ============================================================================

// Objective fields that name location keys, per block (for renaming, uniqueness and cleanup).
export const KEY_FIELDS: Record<string, string[]> = {
    hostile_waves: ['spawns', 'boss.spawn'],
    escort: ['route', 'ambushPoints'],
    pursuit: ['route', 'spawn', 'spawns'],
    checkpoint_route: ['checkpoints'],
    interact_points: ['points'],
    skill_check: ['targets'],
    protect_rescue: ['npcs', 'safe'],
    flee_arrest: ['door', 'suspect', 'fleeTo', 'associates.spawns', 'spawns', 'routes'],
    search_area: ['center', 'clues', 'hiding'],
};

// The location key a block uses when the objective leaves the field out (each block's defaults()).
const DEFAULT_KEYS: Record<string, Record<string, string>> = {
    hostile_waves: { spawns: 'spawns' },
    escort: { route: 'route', ambushPoints: 'ambushPoints' },
    protect_rescue: { npcs: 'hostages', safe: 'safe' },
    flee_arrest: {
        door: 'door',
        suspect: 'suspect',
        fleeTo: 'fleeTo',
        'associates.spawns': 'associates',
        spawns: 'spawns',
        routes: 'routes',
    },
    search_area: { center: 'center', clues: 'clues', hiding: 'hiding' },
};
const DOOR_ONLY = new Set(['door', 'suspect', 'fleeTo', 'associates.spawns']);
const SCATTER_ONLY = new Set(['spawns', 'routes']);

// The location key objective field `field` names: its own value, else the block's default key.
export function keyOf(o: BuilderObjective, field: string): string | null {
    const v = getAt(o, field);
    if (typeof v === 'string' && v !== '') return v;
    if (v !== undefined && v !== null) return null;
    if (o.block === 'flee_arrest') {
        const scatter = o.mode === 'scatter';
        if ((scatter && DOOR_ONLY.has(field)) || (!scatter && SCATTER_ONLY.has(field))) return null;
    }
    if (o.block === 'hostile_waves' && field === 'boss.spawn') return null;
    return DEFAULT_KEYS[o.block]?.[field] ?? null;
}

// Every location key referenced by the objectives (except objective `skip`, 1-based).
export function usedKeys(def: BuilderDefinition, skip?: number): Set<string> {
    const out = new Set<string>();
    asArray(def.objectives).forEach((o, i) => {
        if (skip !== undefined && i + 1 === skip) return;
        (KEY_FIELDS[o.block] ?? []).forEach(f => {
            const v = keyOf(o, f);
            if (v && v !== SHARED_DEVICES) out.add(v);
        });
    });
    return out;
}

// base, or base<n> when another objective already uses base.
export function uniqueKey(def: BuilderDefinition, base: string, index: number, skip?: number): string {
    const used = usedKeys(def, skip);
    if (!used.has(base) && base !== 'start' && base !== 'label') return base;
    for (let n = index; n < index + 50; n += 1) {
        const k = `${base}${n}`;
        if (!used.has(k)) return k;
    }
    return `${base}${Date.now() % 1000}`;
}

// ============================================================================
//                               A NEW OBJECTIVE
// ============================================================================

// A new objective of `block` at position `index` (1-based) with the config defaults, in builder units.
export function newObjective(
    cfg: BuilderConfig,
    def: BuilderDefinition,
    block: string,
    index: number,
    label: string,
): BuilderObjective {
    const key = (base: string) => uniqueKey(def, base, index);
    const r = (k: string, fb?: [number, number, number]) => rangeOf(cfg, block, k, fb).def;
    const hw = (k: string, fb: [number, number, number]) => rangeOf(cfg, 'hostile_waves', k, fb).def;
    const base: BuilderObjective = {
        block,
        label,
        minSeconds: blockMinSeconds(cfg, block),
        presenceRange: presenceOf(cfg, block).def,
    };
    switch (block) {
        case 'hostile_waves': {
            const waves = r('waves', [1, 6, 3]);
            const per = r('perWave', [1, 15, 7]);
            return {
                ...base,
                spawns: key('spawns'),
                waves: Array.from({ length: waves }, () => per),
                nextWave: {
                    aliveAtMost: r('nextWaveAlive', [0, 5, 2]),
                    afterSeconds: r('nextWaveAfter', [30, 300, 90]),
                },
                weapons: listOf(cfg, block, 'weapons'),
                peds: listOf(cfg, block, 'peds'),
                accuracy: r('accuracy', [5, 60, 25]),
                armour: r('armour', [0, 100, 0]),
                health: r('health', [100, 400, 200]),
                behaviour: (optionsOf(cfg, block, 'behaviour').def as string) ?? 'balanced',
                surrender: { belowHealth: HOSTILE_BELOW, chance: r('surrender', [0, 100, 30]) },
                boss: false,
                blockTraffic: r('blockTraffic', [0, 200, 120]),
            };
        }
        case 'escort':
            return {
                ...base,
                route: key('route'),
                vehicle: strOf(cfg, block, 'vehicle', asArray(cfg.allowed?.escortVehicles)[0] ?? 'stockade'),
                speed: r('speed', [20, 120, 60]),
                style: (optionsOf(cfg, block, 'style').def as string) ?? 'normal',
                toughness: r('toughness', [0.5, 3, 1.5]),
                stoppedFail: r('stoppedFail', [15, 120, 60]),
                arrival: r('arrival', [10, 50, 20]),
                ambushPoints: key('ambushPoints'),
                ambush: {
                    waves: r('ambushWaves', [1, 5, 2]),
                    carsPerWave: r('carsPerWave', [1, 5, 2]),
                    perCar: r('perCar', [1, 4, 2]),
                    weapons: listOf(cfg, 'hostile_waves', 'weapons'),
                    accuracy: hw('accuracy', [5, 60, 25]),
                    armour: hw('armour', [0, 100, 0]),
                },
            };
        case 'pursuit':
            return {
                ...base,
                mode: (optionsOf(cfg, block, 'mode').def as string) ?? 'stop',
                vehicles: r('vehicles', [1, 5, 1]),
                models: asArray(cfg.allowed?.vehicles).slice(),
                suspectsPerVehicle: r('suspects', [1, 4, 1]),
                speed: r('speed', [40, 160, 120]),
                style: (optionsOf(cfg, block, 'style').def as string) ?? 'reckless',
                footFlee: r('footFlee', [0, 100, 20]),
                spawn: key('spawn'),
            };
        case 'checkpoint_route':
            return {
                ...base,
                checkpoints: key('checkpoints'),
                use: (optionsOf(cfg, block, 'use').def as string) ?? 'all',
                radius: r('radius', [3, 20, 10]),
                stopFor: r('stopFor', [0, 30, 10]),
                vehicleRequired: flagOf(cfg, block, 'vehicleRequired', true),
                medals: false,
                contactPenalty: r('contactPenalty', [0, 10, 2]),
            };
        case 'interact_points':
            return {
                ...base,
                points: key('points'),
                use: (optionsOf(cfg, block, 'use').def as string) ?? 'all',
                progress: {
                    label: strOf(cfg, block, 'label', 'Checking…'),
                    duration: r('progress', [1, 30, 5]),
                    anim: strOf(cfg, block, 'animation', 'clipboard'),
                },
            };
        case 'skill_check': {
            const diff = optionsOf(cfg, block, 'difficulty');
            const checks = Array.isArray(diff.def)
                ? (diff.def as string[]).slice()
                : ['easy', 'medium', 'medium', 'hard'];
            return {
                ...base,
                targets: key('devices'),
                checks,
                missPenalty: r('missPenalty', [0, 120, 30]),
                failAfter: r('failAfter', [1, 3, 2]),
            };
        }
        case 'protect_rescue':
            return {
                ...base,
                npcs: key('hostages'),
                count: r('npcs', [1, 6, 3]),
                peds: listOf(cfg, block, 'peds'),
                restrained: flagOf(cfg, block, 'restrained', true),
                freeTime: r('freeTime', [1, 15, 6]),
                safe: key('safe'),
                hitPenalty: r('hitPenalty', [0, 100, 50]),
                failIfDies: flagOf(cfg, block, 'failIfDies', true),
            };
        case 'flee_arrest': {
            const resp = (blockCfg(cfg, block).responses ?? { surrender: 50, flee: 30, fight: 20 }) as Record<
                string,
                number
            >;
            return {
                ...base,
                mode: 'door',
                door: key('door'),
                suspect: key('suspect'),
                fleeTo: key('fleeTo'),
                responses: { surrender: resp.surrender ?? 50, flee: resp.flee ?? 30, fight: resp.fight ?? 20 },
                associates: { count: 0, spawns: key('associates') },
                weapons: listOf(cfg, block, 'weapons'),
                escape: { distance: r('escapeDistance', [200, 800, 400]), seconds: r('escapeSeconds', [10, 60, 20]) },
                givesUp: {
                    aim: r('aimDistance', [5, 15, 10]),
                    stun: true,
                    close: {
                        distance: numOf(cfg, block, 'closeDistance', 3),
                        seconds: numOf(cfg, block, 'closeSeconds', 3),
                    },
                },
            };
        }
        case 'search_area': {
            const shrink = asArray(blockCfg(cfg, block).shrinkTo as number[]).filter(n => typeof n === 'number');
            const clues = r('clues', [1, 5, 3]);
            return {
                ...base,
                center: key('center'),
                startRadius: r('startRadius', [200, 1000, 600]),
                clues: key('clues'),
                clueCount: clues,
                shrinkTo: shrinkList(
                    shrink.length ? shrink : [300, 150, 50],
                    clues,
                    r('startRadius', [200, 1000, 600]),
                ),
                hiding: key('hiding'),
                fugitives: r('fugitives', [1, 5, 1]),
                runDistance: r('runDistance', [10, 60, 30]),
            };
        }
        default:
            return base;
    }
}

// `count` decreasing radii below `start` (keeps the given ones where they still fit).
export function shrinkList(given: number[], count: number, start: number): number[] {
    const out: number[] = [];
    let prev = start;
    for (let i = 0; i < count; i += 1) {
        let v = given[i];
        if (typeof v !== 'number' || v >= prev || v <= 0) v = Math.max(10, Math.round((prev * 0.5) / 5) * 5);
        if (v >= prev) v = Math.max(1, prev - 1);
        out.push(v);
        prev = v;
    }
    return out;
}

// ============================================================================
//                        REQUIRED POINTS PER OBJECTIVE
// ============================================================================

function numField(o: BuilderObjective, path: string, fallback: number): number {
    const v = getAt(o, path);
    return typeof v === 'number' && isFinite(v) ? v : fallback;
}

function strField(o: BuilderObjective, path: string): string | null {
    const v = getAt(o, path);
    return typeof v === 'string' && v !== '' ? v : null;
}

// Location keys objective `obj` (at 1-based `index`) needs in every location, and how to place them.
export function pointSpecs(cfg: BuilderConfig, obj: BuilderObjective, index: number): PointSpec[] {
    const out: PointSpec[] = [];
    const add = (field: string, s: Omit<PointSpec, 'key' | 'field' | 'objective'>) => {
        const key = keyOf(obj, field);
        if (!key || key === SHARED_DEVICES) return;
        if (out.some(p => p.key === key)) return;
        out.push({ ...s, key, field, objective: index });
    };
    const b = obj.block;
    const firstPed = (list: unknown, fb: string) => asArray(list as string[])[0] ?? fb;
    const allowedPed = asArray(cfg.allowed?.peds)[0] ?? 'a_m_m_business_01';
    const allowedCar = asArray(cfg.allowed?.vehicles)[0] ?? 'sultan';
    switch (b) {
        case 'hostile_waves': {
            const waves = asArray(obj.waves as number[]).filter(n => typeof n === 'number');
            const largest = waves.length ? Math.max(...waves) : 0;
            const per = numOf(cfg, b, 'spawnPointsPerHostile', 1.5);
            add('spawns', {
                labelKey: 'builder.points.spawns',
                kind: 'ped',
                heading: true,
                multiple: true,
                min: Math.max(1, Math.ceil(per * largest - 1e-9)),
                max: MAX_SPOTS,
                spawn: true,
                model: firstPed(obj.peds, allowedPed),
            });
            if (obj.boss && typeof obj.boss === 'object') {
                add('boss.spawn', {
                    labelKey: 'builder.points.boss',
                    kind: 'ped',
                    heading: true,
                    multiple: false,
                    min: 1,
                    max: 1,
                    spawn: true,
                    model: strField(obj, 'boss.model') ?? allowedPed,
                });
            }
            break;
        }
        case 'escort': {
            const amb = rangeOf(cfg, b, 'ambushPoints', [1, 10, 5]);
            add('route', {
                labelKey: 'builder.points.route',
                kind: 'route',
                heading: false,
                multiple: true,
                min: 2,
                max: 500,
                spawn: false,
                stops: true,
                vehicle: strField(obj, 'vehicle') ?? 'stockade',
                speed: numField(obj, 'speed', 60),
                style: strField(obj, 'style') ?? 'normal',
            });
            add('ambushPoints', {
                labelKey: 'builder.points.ambush',
                kind: 'vehicle',
                heading: true,
                multiple: true,
                min: amb.min,
                max: amb.max,
                spawn: true,
                model: allowedCar,
                minGap: numOf(cfg, b, 'ambushGap', 150),
            });
            break;
        }
        case 'pursuit': {
            const route = strField(obj, 'route');
            if (route) {
                add('route', {
                    labelKey: isLoopKey(route) ? 'builder.points.race_loop' : 'builder.points.flee_route',
                    kind: 'route',
                    heading: false,
                    multiple: true,
                    min: 2,
                    max: 500,
                    spawn: false,
                    loop: isLoopKey(route),
                    vehicle: firstPed(obj.models, allowedCar),
                    speed: numField(obj, 'speed', 120),
                    style: strField(obj, 'style') ?? 'reckless',
                });
            }
            add('spawn', {
                labelKey: 'builder.points.suspect_vehicle',
                kind: 'vehicle',
                heading: true,
                multiple: false,
                min: 1,
                max: 1,
                spawn: true,
                model: firstPed(obj.models, allowedCar),
            });
            add('spawns', {
                labelKey: 'builder.points.suspect_vehicles',
                kind: 'vehicle',
                heading: true,
                multiple: true,
                min: 1,
                max: 10,
                spawn: true,
                model: firstPed(obj.models, allowedCar),
            });
            break;
        }
        case 'checkpoint_route': {
            const cp = rangeOf(cfg, b, 'checkpoints', [2, 20, 2]);
            const use = strField(obj, 'use');
            const need = use === 'random' ? Math.max(cp.min, numField(obj, 'count', cp.min)) : cp.min;
            add('checkpoints', {
                labelKey: 'builder.points.checkpoints',
                kind: 'route',
                heading: false,
                multiple: true,
                min: need,
                max: cp.max,
                spawn: false,
                placeable: true,
                thinTo: cp.max,
                vehicle: allowedCar,
                speed: 80,
                style: 'normal',
            });
            break;
        }
        case 'interact_points': {
            const pr = rangeOf(cfg, b, 'points', [1, 10, 1]);
            const use = strField(obj, 'use');
            const need = use === 'random' ? Math.max(pr.min, numField(obj, 'count', pr.min)) : pr.min;
            add('points', {
                labelKey: 'builder.points.interact',
                kind: 'marker',
                heading: false,
                multiple: true,
                min: need,
                max: pr.max,
                spawn: false,
            });
            break;
        }
        case 'skill_check':
            add('targets', {
                labelKey: 'builder.points.devices',
                kind: 'marker',
                heading: false,
                multiple: true,
                min: 1,
                max: 10,
                spawn: false,
            });
            break;
        case 'protect_rescue': {
            const count = numField(obj, 'count', rangeOf(cfg, b, 'npcs', [1, 6, 3]).def);
            add('npcs', {
                labelKey: 'builder.points.hostages',
                kind: 'ped',
                heading: true,
                multiple: true,
                min: Math.max(1, count),
                max: 20,
                spawn: true,
                model: firstPed(obj.peds, allowedPed),
            });
            add('safe', {
                labelKey: 'builder.points.safe',
                kind: 'marker',
                heading: false,
                multiple: false,
                min: 1,
                max: 1,
                spawn: false,
                radius: 6,
            });
            break;
        }
        case 'flee_arrest': {
            const mode = strField(obj, 'mode') ?? 'door';
            if (mode === 'scatter') {
                add('spawns', {
                    labelKey: 'builder.points.inmates',
                    kind: 'ped',
                    heading: true,
                    multiple: true,
                    min: 1,
                    max: MAX_SPOTS,
                    spawn: true,
                    model: allowedPed,
                });
                add('routes', {
                    labelKey: 'builder.points.flee_paths',
                    kind: 'marker',
                    heading: false,
                    multiple: true,
                    lists: true,
                    min: 2,
                    max: 12,
                    spawn: false,
                });
            } else {
                add('door', {
                    labelKey: 'builder.points.door',
                    kind: 'marker',
                    heading: true,
                    multiple: false,
                    min: 1,
                    max: 1,
                    spawn: false,
                });
                add('suspect', {
                    labelKey: 'builder.points.suspect',
                    kind: 'ped',
                    heading: true,
                    multiple: false,
                    min: 1,
                    max: 1,
                    spawn: true,
                    model: allowedPed,
                });
                if (numField(obj, 'responses.flee', 0) > 0) {
                    add('fleeTo', {
                        labelKey: 'builder.points.flee_to',
                        kind: 'marker',
                        heading: false,
                        multiple: true,
                        min: 1,
                        max: 10,
                        spawn: false,
                    });
                }
                const assoc = numField(obj, 'associates.count', 0);
                if (assoc > 0) {
                    add('associates.spawns', {
                        labelKey: 'builder.points.associates',
                        kind: 'ped',
                        heading: true,
                        multiple: true,
                        min: assoc,
                        max: 20,
                        spawn: true,
                        model: allowedPed,
                    });
                }
            }
            break;
        }
        case 'search_area': {
            const clueCount = numField(obj, 'clueCount', 3);
            add('center', {
                labelKey: 'builder.points.center',
                kind: 'marker',
                heading: false,
                multiple: false,
                min: 1,
                max: 1,
                spawn: false,
                radius: numField(obj, 'startRadius', 600),
            });
            add('clues', {
                labelKey: 'builder.points.clues',
                kind: 'marker',
                heading: false,
                multiple: true,
                min: Math.max(SEARCH_MIN_SPOTS, clueCount),
                max: MAX_SPOTS,
                spawn: false,
            });
            add('hiding', {
                labelKey: 'builder.points.hiding',
                kind: 'ped',
                heading: true,
                multiple: true,
                min: SEARCH_MIN_SPOTS,
                max: MAX_SPOTS,
                spawn: true,
                model: allowedPed,
            });
            break;
        }
        default:
            break;
    }
    return out;
}

// Every point spec of the mission (objective order), one per location key.
export function missionPointSpecs(cfg: BuilderConfig, def: BuilderDefinition): PointSpec[] {
    const out: PointSpec[] = [];
    asArray(def.objectives).forEach((o, i) => {
        pointSpecs(cfg, o, i + 1).forEach(s => {
            const prev = out.find(p => p.key === s.key);
            if (!prev) out.push(s);
            else if (s.min > prev.min) prev.min = s.min;
        });
    });
    return out;
}

export function isLoopKey(key: string): boolean {
    return /^raceLoop\d*$/.test(key);
}

// ============================================================================
//                 ARMED NPCS (mirrors each block's armedCount)
// ============================================================================

export function armedCount(obj: BuilderObjective): number {
    const n = (path: string) => {
        const v = getAt(obj, path);
        return typeof v === 'number' && isFinite(v) ? Math.floor(v) : 0;
    };
    switch (obj.block) {
        case 'hostile_waves':
            return (
                asArray(obj.waves as number[]).reduce((s, w) => s + (typeof w === 'number' ? w : 0), 0) +
                (obj.boss && typeof obj.boss === 'object' ? 1 : 0)
            );
        case 'escort':
            return n('ambush.waves') * n('ambush.carsPerWave') * n('ambush.perCar');
        case 'pursuit':
            return obj.neverShoots === false ? n('vehicles') * n('suspectsPerVehicle') : 0;
        case 'flee_arrest':
            if (obj.mode === 'scatter') return n('armedShare') > 0 ? n('suspects') : 0;
            return n('associates.count') + (n('responses.fight') > 0 ? 1 : 0);
        default:
            return 0;
    }
}

export function totalArmed(def: BuilderDefinition): number {
    return asArray(def.objectives).reduce((s, o) => s + armedCount(o), 0);
}

// ============================================================================
//                                   SCALING
// ============================================================================

export interface Scalable {
    field: string;
    labelKey: string;
    suggested: boolean;
    max: number;
}

// The counts of an objective that can scale with the tier (suggested ones first).
export function scalables(cfg: BuilderConfig, obj: BuilderObjective): Scalable[] {
    const b = obj.block;
    const r = (k: string, fb: [number, number, number]) => rangeOf(cfg, b, k, fb).max;
    switch (b) {
        case 'hostile_waves':
            return [
                { field: 'waves', labelKey: 'builder.scale.waves', suggested: true, max: r('perWave', [1, 15, 7]) },
            ];
        case 'escort':
            return [
                {
                    field: 'ambush.waves',
                    labelKey: 'builder.scale.ambush_waves',
                    suggested: true,
                    max: r('ambushWaves', [1, 5, 2]),
                },
                {
                    field: 'ambush.carsPerWave',
                    labelKey: 'builder.scale.cars_per_wave',
                    suggested: false,
                    max: r('carsPerWave', [1, 5, 2]),
                },
                {
                    field: 'ambush.perCar',
                    labelKey: 'builder.scale.per_car',
                    suggested: false,
                    max: r('perCar', [1, 4, 2]),
                },
            ];
        case 'pursuit':
            return [
                {
                    field: 'vehicles',
                    labelKey: 'builder.scale.vehicles',
                    suggested: true,
                    max: r('vehicles', [1, 5, 1]),
                },
                {
                    field: 'suspectsPerVehicle',
                    labelKey: 'builder.scale.suspects_per_vehicle',
                    suggested: false,
                    max: r('suspects', [1, 4, 1]),
                },
            ];
        case 'protect_rescue':
            return [
                { field: 'count', labelKey: 'builder.scale.hostages', suggested: false, max: r('npcs', [1, 6, 3]) },
            ];
        case 'flee_arrest':
            return obj.mode === 'scatter'
                ? [
                      {
                          field: 'suspects',
                          labelKey: 'builder.scale.suspects',
                          suggested: true,
                          max: r('suspects', [1, 10, 1]),
                      },
                  ]
                : [
                      {
                          field: 'associates.count',
                          labelKey: 'builder.scale.associates',
                          suggested: true,
                          max: Math.max(1, r('suspects', [1, 10, 1]) - 1),
                      },
                  ];
        case 'search_area':
            return [
                {
                    field: 'fugitives',
                    labelKey: 'builder.scale.fugitives',
                    suggested: true,
                    max: r('fugitives', [1, 5, 1]),
                },
            ];
        case 'interact_points':
            return obj.use === 'random'
                ? [
                      {
                          field: 'count',
                          labelKey: 'builder.scale.points_used',
                          suggested: false,
                          max: r('points', [1, 10, 1]),
                      },
                  ]
                : [];
        case 'checkpoint_route':
            return obj.use === 'random'
                ? [
                      {
                          field: 'count',
                          labelKey: 'builder.scale.checkpoints_used',
                          suggested: false,
                          max: r('checkpoints', [2, 20, 2]),
                      },
                  ]
                : [];
        default:
            return [];
    }
}

// Blocks whose presence suggests switching vehicle-damage penalties off.
export function suggestsNoVehiclePenalties(def: BuilderDefinition): boolean {
    return asArray(def.objectives).some(o => o.block === 'pursuit' || o.block === 'escort') || totalArmed(def) > 0;
}

// The tier name the publishing test needs (the first tier whose maxParticipants >= maxOfficers).
export function requiredTierFor(cfg: BuilderConfig, maxOfficers: number): string {
    const tiers = asArray(cfg.tiers);
    const hit = tiers.find(t => t.maxParticipants >= maxOfficers);
    return (hit ?? tiers[tiers.length - 1])?.name ?? 'standard';
}
