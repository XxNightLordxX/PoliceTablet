// src/builder/defUtils.ts · helpers for the builder definition (docs/notes/builder_protocol.md §1): Lua lists
// that arrive as {} normalised to arrays, immutable path updates, error lookup by path, vectors and routes.
import { asArray } from '../shared/data';
import type {
  BuilderDefinition, BuilderError, BuilderLocation, BuilderObjective, BuilderRoute, BuilderScalingEntry, Vec, Vec3,
} from '../types/builder_server';
import type { BuilderStepKey } from '../types/builder_client';

export const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v ?? null)) as T;

export function isVec(v: unknown): v is Vec {
  return !!v && typeof v === 'object' && !Array.isArray(v)
    && typeof (v as Vec3).x === 'number' && typeof (v as Vec3).y === 'number' && typeof (v as Vec3).z === 'number';
}

export function isRoute(v: unknown): v is BuilderRoute {
  return !!v && typeof v === 'object' && !Array.isArray(v) && Array.isArray((v as BuilderRoute).points);
}

/** Every vector of a location value (vec, list, labelled points, list of lists, route). */
export function pointsOf(v: unknown): Vec[] {
  if (isVec(v)) return [v];
  if (isRoute(v)) return asArray(v.points).filter(isVec);
  if (Array.isArray(v)) {
    const out: Vec[] = [];
    v.forEach((item) => {
      if (isVec(item)) out.push(item);
      else if (item && typeof item === 'object' && isVec((item as { coords?: unknown }).coords)) out.push((item as { coords: Vec }).coords);
      else if (Array.isArray(item)) out.push(...pointsOf(item));
    });
    return out;
  }
  return [];
}

/** A list of lists (flee routes): each inner list. */
export function listsOf(v: unknown): Vec[][] {
  if (!Array.isArray(v)) return [];
  if (v.length && isVec(v[0])) return [v.filter(isVec) as Vec[]];
  return v.map((inner) => pointsOf(inner)).filter((l) => l.length > 0);
}

export function dist2d(a: { x: number; y: number }, b: { x: number; y: number }): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

export function dist3d(a: Vec3, b: Vec3): number {
  return Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
}

export function routeLength(points: Vec3[]): number {
  let len = 0;
  for (let i = 1; i < points.length; i += 1) len += dist3d(points[i - 1], points[i]);
  return len;
}

/** Evenly thinned copy keeping the first and the last point (as CP.Builder.thin in Lua). */
export function thin<T>(points: T[], max: number): T[] {
  const n = points.length;
  if (n <= max || max < 2) return points.slice();
  const out: T[] = [];
  let last = -1;
  for (let i = 0; i < max; i += 1) {
    const idx = Math.round((i * (n - 1)) / (max - 1));
    if (idx > last) {
      out.push(points[idx]);
      last = idx;
    }
  }
  return out;
}

// ── normalising (Lua {} → []) ─────────────────────────────────────────────────────

function fixDeep(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(fixDeep);
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    const keys = Object.keys(o);
    if (keys.length === 0) return o;
    const out: Record<string, unknown> = {};
    keys.forEach((k) => {
      out[k] = fixDeep(o[k]);
    });
    return out;
  }
  return v;
}

const LIST_FIELDS: (keyof BuilderDefinition)[] = ['departments', 'locations', 'objectives', 'scaling', 'items', 'bonuses', 'penalties'];

/** Objective fields renamed after missions were published (block -> { old name: new name }), as the server's
 *  RENAMED_FIELDS (modules/builder/server.lua): checkpoint_route's policeVehicle is now vehicleRequired. */
const RENAMED_FIELDS: Record<string, Record<string, string>> = { checkpoint_route: { policeVehicle: 'vehicleRequired' } };

/** A definition with every top-level list as an array (Lua sends empty tables as {}); renamed objective fields
 *  under their new name. */
export function normalizeDefinition(input: BuilderDefinition | null | undefined): BuilderDefinition {
  const d = (fixDeep(clone(input ?? {})) ?? {}) as BuilderDefinition;
  LIST_FIELDS.forEach((k) => {
    (d as unknown as Record<string, unknown>)[k] = asArray((d as unknown as Record<string, unknown[]>)[k]);
  });
  d.label = typeof d.label === 'string' ? d.label : '';
  d.description = typeof d.description === 'string' ? d.description : '';
  d.locations = d.locations.map((l) => (l && typeof l === 'object' ? l : { label: '' })) as BuilderLocation[];
  d.objectives = d.objectives.filter((o) => o && typeof o === 'object') as BuilderObjective[];
  d.objectives.forEach((o) => {
    // renamed fields: a draft or published file may still use the old name (read as the new one)
    Object.entries(RENAMED_FIELDS[o.block] ?? {}).forEach(([oldName, newName]) => {
      const rec = o as Record<string, unknown>;
      if (rec[oldName] !== undefined) {
        if (rec[newName] === undefined) rec[newName] = rec[oldName];
        delete rec[oldName];
      }
    });
    // lists inside objectives
    ['waves', 'weapons', 'peds', 'models', 'checks', 'shrinkTo'].forEach((f) => {
      const v = (o as Record<string, unknown>)[f];
      if (v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === 0) (o as Record<string, unknown>)[f] = [];
    });
  });
  d.locations.forEach((l) => {
    Object.keys(l).forEach((k) => {
      const v = l[k];
      if (isRoute(v)) {
        v.points = asArray(v.points);
        if (v.stops !== undefined) v.stops = asArray(v.stops);
      } else if (v && typeof v === 'object' && !Array.isArray(v) && !isVec(v) && k !== 'start' && Object.keys(v).length === 0) {
        delete l[k];
      }
    });
  });
  return d;
}

// ── paths ──────────────────────────────────────────────────────────────────────

export function getAt(obj: unknown, path: string): unknown {
  let cur: unknown = obj;
  for (const part of path.split('.')) {
    if (cur === null || cur === undefined || typeof cur !== 'object') return undefined;
    cur = (cur as Record<string, unknown>)[part];
  }
  return cur;
}

/** Sets obj[path] in place (creates objects on the way); undefined deletes the leaf. */
export function setAt(obj: Record<string, unknown>, path: string, value: unknown): void {
  const parts = path.split('.');
  let cur: Record<string, unknown> = obj;
  for (let i = 0; i < parts.length - 1; i += 1) {
    const p = parts[i];
    const next = cur[p];
    if (!next || typeof next !== 'object' || Array.isArray(next)) cur[p] = {};
    cur = cur[p] as Record<string, unknown>;
  }
  const leaf = parts[parts.length - 1];
  if (value === undefined) delete cur[leaf];
  else cur[leaf] = value;
}

// ── errors ─────────────────────────────────────────────────────────────────────

export function errorsAt(errors: BuilderError[], path: string): BuilderError[] {
  return errors.filter((e) => e.path === path);
}

export function errorsUnder(errors: BuilderError[], prefix: string): BuilderError[] {
  return errors.filter((e) => e.path === prefix || e.path.startsWith(`${prefix}.`));
}

export function messageAt(errors: BuilderError[], ...paths: string[]): string | undefined {
  const list = errors.filter((e) => paths.includes(e.path));
  return list.length ? list.map((e) => e.message).join(' ') : undefined;
}

const DETAIL_PATHS = ['label', 'description', 'type', 'departments', 'minOfficers', 'maxOfficers', 'difficulty',
  'timeLimit', 'startTimeout', 'cooldown', 'vehiclePenalties', 'payout'];

/** The builder step an error belongs to. */
export function stepOfError(e: BuilderError): BuilderStepKey {
  const p = e.path || '';
  if (DETAIL_PATHS.includes(p) || p.startsWith('items') || p.startsWith('bonuses') || p.startsWith('penalties')) return 'details';
  if (p === 'objectives' || /^objectives\.\d+\.block$/.test(p)) return 'blocks';
  if (p.startsWith('objectives.')) return 'settings';
  if (p.startsWith('locations')) return 'locations';
  if (p.startsWith('scaling')) return 'scaling';
  return 'publish';
}

/** Objective index (1-based) of an objectives.N… error, else null. */
export function objectiveOfError(e: BuilderError): number | null {
  const m = (e.path || '').match(/^objectives\.(\d+)/);
  return m ? Number(m[1]) : null;
}

/** Location index (1-based) of a locations.N… error, else null. */
export function locationOfError(e: BuilderError): number | null {
  const m = (e.path || '').match(/^locations\.(\d+)/);
  return m ? Number(m[1]) : null;
}

// ── scaling paths ──────────────────────────────────────────────────────────────

export function scalingPath(entry: BuilderScalingEntry): string {
  return typeof entry === 'string' ? entry : entry?.path ?? '';
}

/** Rewrites objectives.N.* scaling paths after objectives were removed or moved (map: old index → new index | null). */
export function remapScaling(list: BuilderScalingEntry[], map: (oldIndex: number) => number | null): BuilderScalingEntry[] {
  const out: BuilderScalingEntry[] = [];
  list.forEach((entry) => {
    const path = scalingPath(entry);
    const m = path.match(/^objectives\.(\d+)\.(.+)$/);
    if (!m) return;
    const next = map(Number(m[1]));
    if (next === null) return;
    const np = `objectives.${next}.${m[2]}`;
    out.push(typeof entry === 'string' ? np : { ...entry, path: np });
  });
  return out;
}

export function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
