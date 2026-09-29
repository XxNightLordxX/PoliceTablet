// src/builder/applyResult.ts · writes a builder client result (docs/notes/builder_protocol.md §6) into the
// draft: placed points into definition.locations[location - 1][key] (a single vector for single-point keys,
// a list otherwise, one more list for flee paths, { coords, radius } for the start), a recorded road route
// { points, stops?, loop? }, and the route meta (length, rejected samples, unreachable / failed waypoints)
// that the Locations step shows but the definition never stores.
import type { BuilderConfig, BuilderDefinition, BuilderRoute, Vec, Vec3 } from '../types/builder_server';
import type { BuilderClientResultEx, PointSpec, RouteMeta } from '../types/builder_client';
import { clone, isVec, listsOf, pointsOf, round2, thin } from './defUtils';
import { startRadiusRange } from './schema';

export interface Applied {
  def: BuilderDefinition | null;
  meta: Partial<RouteMeta> | null;
  /** locale key + vars of a short confirmation */
  messageKey: string;
  vars: Record<string, string | number>;
  tone: 'success' | 'warning' | 'info';
}

function vec3(p: Vec): Vec3 {
  return { x: round2(p.x), y: round2(p.y), z: round2(p.z) };
}

function vecKeep(p: Vec, heading: boolean): Vec {
  const out: Vec = { x: round2(p.x), y: round2(p.y), z: round2(p.z) } as Vec;
  if (heading && typeof (p as { w?: number }).w === 'number') (out as { w: number }).w = round2((p as { w: number }).w);
  return out;
}

export function applyResult(input: BuilderDefinition, result: BuilderClientResultEx, spec: PointSpec | null, cfg: BuilderConfig | null): Applied {
  const nothing: Applied = { def: null, meta: null, messageKey: 'builder.result.cancelled', vars: {}, tone: 'info' };
  const li = Number(result.location);
  if (!Number.isInteger(li) || li < 1 || li > input.locations.length) return { ...nothing, messageKey: 'builder.result.no_location' };
  if (result.cancelled) return nothing;
  const def = clone(input);
  const loc = def.locations[li - 1];
  const key = result.key;

  if (result.kind === 'placement') {
    const pts = Array.isArray(result.points) ? result.points.filter(isVec) : [];
    if (key === 'start') {
      if (!pts.length) delete loc.start;
      else {
        const [lo, hi, dflt] = startRadiusRange(cfg, input);   // exactly the search circle when there is one
        const r = typeof result.radius === 'number' ? Math.min(hi, Math.max(lo, Math.round(result.radius))) : (loc.start?.radius ?? dflt);
        loc.start = { coords: vec3(pts[0]), radius: r };
      }
      return { def, meta: null, messageKey: 'builder.result.start', vars: { location: li }, tone: 'success' };
    }
    const heading = spec ? spec.heading : pts.some((p) => typeof (p as { w?: number }).w === 'number');
    const kept = pts.map((p) => vecKeep(p, heading));
    if (spec?.lists) {
      const lists = listsOf(loc[key]);
      if (kept.length) lists.push(kept.map(vec3));
      if (lists.length) loc[key] = lists as unknown as Vec3[][];
      else delete loc[key];
      return { def, meta: null, messageKey: 'builder.result.path', vars: { n: kept.length, location: li }, tone: kept.length ? 'success' : 'info' };
    }
    const single = spec ? !spec.multiple : isVec(loc[key]);
    if (single) {
      if (kept.length) loc[key] = kept[kept.length - 1];
      else delete loc[key];
    } else if (kept.length) loc[key] = kept;
    else delete loc[key];
    return { def, meta: null, messageKey: 'builder.result.placed', vars: { n: kept.length, location: li }, tone: 'success' };
  }

  if (result.kind === 'recording') {
    const route = result.route ?? { points: [] };
    let points = (Array.isArray(route.points) ? route.points : []).filter(isVec).map(vec3);
    if (points.length < 2) return { ...nothing, messageKey: 'builder.result.nothing_recorded', tone: 'warning' };
    let stops = Array.isArray(route.stops) ? route.stops.filter((s) => s && Number.isInteger(s.at)) : [];
    let thinned = 0;
    if (spec?.thinTo && points.length > spec.thinTo) {
      thinned = points.length;
      points = thin(points, spec.thinTo);
      stops = [];
    }
    const value: BuilderRoute = { points };
    if ((spec?.stops || stops.length) && stops.length) value.stops = stops.map((s) => ({ at: s.at, wait: s.wait }));
    if (spec?.loop || route.loop) value.loop = true;
    loc[key] = value;
    const meta: Partial<RouteMeta> = {
      length: typeof result.length === 'number' ? result.length : 0,
      rejected: typeof result.rejected === 'number' ? result.rejected : 0,
      rejectedSamples: Array.isArray(result.rejectedSamples) ? result.rejectedSamples.filter(isVec).map(vec3) : [],
      unreachable: thinned ? [] : (Array.isArray(result.unreachable) ? result.unreachable.filter((n) => Number.isInteger(n)) : []),
      failed: [],
      completed: undefined,
      testedAt: undefined,
      droppedStops: result.droppedStops ?? 0,
      thinned,
    };
    return {
      def, meta, messageKey: thinned ? 'builder.result.recorded_thinned' : 'builder.result.recorded',
      vars: { km: (meta.length! / 1000).toFixed(2), n: points.length, from: thinned, location: li },
      tone: meta.rejected || (meta.unreachable ?? []).length ? 'warning' : 'success',
    };
  }

  if (result.kind === 'testdrive') {
    const failed = Array.isArray(result.failed) ? result.failed.filter((n) => Number.isInteger(n)) : [];
    const meta: Partial<RouteMeta> = { failed, completed: !!result.completed, testedAt: Math.floor(Date.now() / 1000) };
    return {
      def: null, meta,
      messageKey: failed.length ? 'builder.result.drive_failed' : result.completed ? 'builder.result.drive_ok' : 'builder.result.drive_stopped',
      vars: { n: failed.length, list: failed.join(', ') },
      tone: failed.length ? 'warning' : result.completed ? 'success' : 'info',
    };
  }
  return nothing;
}

/** Existing points of a key (for the placement payload). */
export function existingPoints(value: unknown): Vec[] {
  return pointsOf(value);
}
