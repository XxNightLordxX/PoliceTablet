// The point list under the location map: one row per stored point (the start, then every point of every key in
// spec order), and the edits its buttons make. Pure functions, no React: the builder screens and the node check in
// tests/builder_points_spec.lua share them.

import type { BuilderClientResultEx, PointSpec } from '../types/builder_client';
import type { BuilderLocation, Vec } from '../types/builder_server';
import { dist2d, isRoute, isVec } from './defUtils';

export interface PointListRow {
    // 'start' or the location key
    key: string;
    // the key's position in the spec list (its map colour), -1 for the start
    specIndex: number;
    // 1-based position of the point inside its key
    index: number;
    point: Vec;
    // metres from the start on the map (2D), null without a start (or for the start itself)
    fromStart: number | null;
    // the street stored with the point (kerb spots), null when none was stored
    street: string | null;
}

// Keys whose points are listed one by one: plain points, never a recorded road route or a list of flee paths
// (those have their own controls on the key's row).
export function listsPointsOf(spec: PointSpec, value: unknown): boolean {
    return !spec.lists && !isRoute(value);
}

// The stored entries of a key: each is a point or a { coords, street? } spot.
function entriesOf(value: unknown): { point: Vec; street: string | null }[] {
    const list = isVec(value) ? [value] : Array.isArray(value) ? value : [];
    const out: { point: Vec; street: string | null }[] = [];
    list.forEach(item => {
        if (isVec(item)) out.push({ point: item, street: null });
        else if (item && typeof item === 'object' && isVec((item as { coords?: unknown }).coords)) {
            const street = (item as { street?: unknown }).street;
            out.push({
                point: (item as { coords: Vec }).coords,
                street: typeof street === 'string' && street !== '' ? street : null,
            });
        }
    });
    return out;
}

export function pointListRows(loc: BuilderLocation, specs: PointSpec[]): PointListRow[] {
    const start = loc.start?.coords ?? null;
    const rows: PointListRow[] = [];
    if (start) rows.push({ key: 'start', specIndex: -1, index: 1, point: start, fromStart: null, street: null });
    specs.forEach((spec, specIndex) => {
        const value = loc[spec.key];
        if (!listsPointsOf(spec, value)) return;
        entriesOf(value).forEach((e, i) =>
            rows.push({
                key: spec.key,
                specIndex,
                index: i + 1,
                point: e.point,
                fromStart: start ? dist2d(start, e.point) : null,
                street: e.street,
            }),
        );
    });
    return rows;
}

// Delete point `index` (1-based) of a key in a draft location; the key goes when its last point goes.
// False when there is no such point.
export function removePointAt(loc: BuilderLocation, key: string, index: number): boolean {
    if (key === 'start') {
        if (!loc.start || index !== 1) return false;
        delete loc.start;
        return true;
    }
    const value = loc[key];
    if (isVec(value)) {
        if (index !== 1) return false;
        delete loc[key];
        return true;
    }
    if (!Array.isArray(value) || index < 1 || index > value.length) return false;
    value.splice(index - 1, 1);
    if (!value.length) delete loc[key];
    return true;
}

// "Set here" on point `index` of a multiple key: the builderHere payload carries the other points (so the spacing
// checks do not compare the new spot with the point it replaces) ...
export function pointsWithout(points: Vec[], index: number): Vec[] {
    return points.filter((_, i) => i !== index - 1);
}

// ... and its answer (the other points with the new one added last) is put back in order: the new point takes
// position `index`, the street names follow their points.
export function resultReplacing(result: BuilderClientResultEx, index: number): BuilderClientResultEx {
    if (result.kind !== 'placement' || !Array.isArray(result.points) || !result.points.length) return result;
    const move = <T>(list: T[]): T[] => {
        const out = list.slice(0, -1);
        out.splice(Math.min(index - 1, out.length), 0, list[list.length - 1]);
        return out;
    };
    const out = { ...result, points: move(result.points) };
    if (Array.isArray(result.streets) && result.streets.length === result.points.length)
        out.streets = move(result.streets);
    return out;
}
