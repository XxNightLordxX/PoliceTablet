// A schematic map (SVG, north up, metres) of one location: the start and its radius,

import { useEffect, useMemo, useRef, useState, type RefObject } from 'react';
import { cx } from '../shared/cx';
import { formatDistance } from '../shared/format';
import { t } from '../shared/i18n';
import type { BuilderConfig, BuilderLocation, Vec, Vec3 } from '../types/builder_server';
import type { PointSpec, RouteMeta } from '../types/builder_client';
import { isRoute, listsOf, pointsOf } from './defUtils';

export const KEY_COLOURS = [
    'var(--cp-info)',
    'var(--cp-success)',
    'var(--cp-xp-platinum)',
    'var(--cp-accent)',
    'var(--cp-tier-major)',
    'var(--cp-xp-gold)',
    'var(--cp-xp-bronze)',
    'var(--cp-xp-silver)',
];

export interface LocationMapProps {
    location: BuilderLocation;
    specs: PointSpec[];
    cfg: BuilderConfig;
    meta: (key: string) => RouteMeta | null;
    focusKey?: string | null;
    height?: number;
    className?: string;
}

interface Box {
    minX: number;
    maxX: number;
    minY: number;
    maxY: number;
}

function grow(b: Box, x: number, y: number, r = 0) {
    b.minX = Math.min(b.minX, x - r);
    b.maxX = Math.max(b.maxX, x + r);
    b.minY = Math.min(b.minY, y - r);
    b.maxY = Math.max(b.maxY, y + r);
}

function niceStep(span: number): number {
    const steps = [25, 50, 100, 200, 250, 500, 1000, 2000];
    return steps.find(s => span / s <= 8) ?? 5000;
}

// Width / height of the map box, measured so the schematic fills it at any tablet size.
function useAspect(ref: RefObject<HTMLDivElement | null>): { aspect: number; width: number } {
    const [size, setSize] = useState({ aspect: 1.8, width: 900 });
    useEffect(() => {
        const el = ref.current;
        if (!el || typeof ResizeObserver === 'undefined') return undefined;
        const measure = () => {
            const r = el.getBoundingClientRect();
            if (r.width > 0 && r.height > 0) {
                const aspect = Math.min(6, Math.max(1.2, r.width / r.height));
                setSize(old =>
                    Math.abs(old.aspect - aspect) < 0.01 && Math.abs(old.width - r.width) < 1
                        ? old
                        : { aspect, width: r.width },
                );
            }
        };
        measure();
        const ro = new ResizeObserver(measure);
        ro.observe(el);
        return () => ro.disconnect();
    }, [ref]);
    return size;
}

export function LocationMap({ location, specs, cfg, meta, focusKey, height = 260, className }: LocationMapProps) {
    const start = location.start;
    const keepOut = Number(cfg.minSpawnFromStart) || 30;
    const boxRef = useRef<HTMLDivElement | null>(null);
    const { aspect, width } = useAspect(boxRef);
    const data = useMemo(() => {
        const box: Box = { minX: Infinity, maxX: -Infinity, minY: Infinity, maxY: -Infinity };
        if (start) {
            grow(box, start.coords.x, start.coords.y, Math.max(start.radius, keepOut));
        }
        const layers = specs.map((s, i) => {
            const v = location[s.key];
            const colour = KEY_COLOURS[i % KEY_COLOURS.length];
            const pts = pointsOf(v);
            pts.forEach(p => grow(box, p.x, p.y, 4));
            const m = meta(s.key);
            (m?.rejectedSamples ?? []).forEach(p => grow(box, p.x, p.y, 4));
            return { spec: s, colour, pts, route: isRoute(v) ? v : null, lists: s.lists ? listsOf(v) : null, meta: m };
        });
        if (!isFinite(box.minX)) {
            box.minX = -100;
            box.maxX = 100;
            box.minY = -100;
            box.maxY = 100;
        }
        const minSpan = 160;
        const cx0 = (box.minX + box.maxX) / 2;
        const cy0 = (box.minY + box.maxY) / 2;
        const span = Math.max(minSpan, box.maxX - box.minX, (box.maxY - box.minY) * aspect) * 1.12;
        const w = span;
        const h = span / aspect;
        const view = { x: cx0 - w / 2, y: -(cy0 + h / 2), w, h };
        const zones = (cfg.noBuildZones ?? []).filter(
            z =>
                z.coords.x + z.radius > cx0 - w / 2 &&
                z.coords.x - z.radius < cx0 + w / 2 &&
                z.coords.y + z.radius > cy0 - h / 2 &&
                z.coords.y - z.radius < cy0 + h / 2,
        );
        return { layers, view, zones, step: niceStep(Math.min(w, h * 3)) };
    }, [location, specs, start, keepOut, meta, cfg.noBuildZones, aspect]);

    const { view, step } = data;
    const px = view.w / Math.max(200, width); // metres per screen pixel
    const sx = (p: { x: number }) => p.x;
    const sy = (p: { y: number }) => -p.y;
    const gridX: number[] = [];
    const gridY: number[] = [];
    for (let x = Math.ceil(view.x / step) * step; x < view.x + view.w; x += step) gridX.push(x);
    for (let y = Math.ceil(view.y / step) * step; y < view.y + view.h; y += step) gridY.push(y);
    const dot = 5 * px;

    const polyline = (pts: Vec3[]) => pts.map(p => `${sx(p)},${sy(p)}`).join(' ');

    return (
        <div ref={boxRef} className={cx('builder_client-map', className)} style={{ height }}>
            <svg
                viewBox={`${view.x} ${view.y} ${view.w} ${view.h}`}
                preserveAspectRatio="xMidYMid meet"
                role="img"
                aria-label={t('builder.map.aria')}
            >
                <rect x={view.x} y={view.y} width={view.w} height={view.h} className="builder_client-map__bg" />
                {gridX.map(x => (
                    <line
                        key={`gx${x}`}
                        x1={x}
                        x2={x}
                        y1={view.y}
                        y2={view.y + view.h}
                        className="builder_client-map__grid"
                        strokeWidth={px}
                    />
                ))}
                {gridY.map(y => (
                    <line
                        key={`gy${y}`}
                        y1={y}
                        y2={y}
                        x1={view.x}
                        x2={view.x + view.w}
                        className="builder_client-map__grid"
                        strokeWidth={px}
                    />
                ))}
                {data.zones.map(z => (
                    <circle
                        key={z.label}
                        cx={z.coords.x}
                        cy={-z.coords.y}
                        r={z.radius}
                        className="builder_client-map__zone"
                        strokeWidth={1.5 * px}
                    >
                        <title>{t('builder.map.zone_named', { label: z.label })}</title>
                    </circle>
                ))}
                {start ? (
                    <g>
                        <circle
                            cx={start.coords.x}
                            cy={-start.coords.y}
                            r={start.radius}
                            className="builder_client-map__start"
                            strokeWidth={1.5 * px}
                        />
                        <circle
                            cx={start.coords.x}
                            cy={-start.coords.y}
                            r={keepOut}
                            className="builder_client-map__keepout"
                            strokeWidth={1.2 * px}
                            strokeDasharray={`${4 * px} ${3 * px}`}
                        />
                        <circle
                            cx={start.coords.x}
                            cy={-start.coords.y}
                            r={dot * 1.4}
                            className="builder_client-map__start-dot"
                        />
                    </g>
                ) : null}
                {data.layers.map(l => {
                    const faded = focusKey && focusKey !== l.spec.key;
                    const style = { color: l.colour, opacity: faded ? 0.35 : 1 };
                    if (l.route) {
                        const pts = l.route.points;
                        const failed = new Set(l.meta?.failed ?? []);
                        const unreachable = new Set(l.meta?.unreachable ?? []);
                        return (
                            <g key={l.spec.key} style={style}>
                                <polyline
                                    points={polyline(pts)}
                                    className="builder_client-map__route"
                                    strokeWidth={3 * px}
                                />
                                {pts
                                    .slice(0, -1)
                                    .map((p, i) =>
                                        unreachable.has(i + 1) ? (
                                            <line
                                                key={`u${i}`}
                                                x1={sx(p)}
                                                y1={sy(p)}
                                                x2={sx(pts[i + 1])}
                                                y2={sy(pts[i + 1])}
                                                className="builder_client-map__bad-seg"
                                                strokeWidth={3.5 * px}
                                                strokeDasharray={`${5 * px} ${4 * px}`}
                                            />
                                        ) : null,
                                    )}
                                {pts.map((p, i) => (
                                    <circle
                                        key={i}
                                        cx={sx(p)}
                                        cy={sy(p)}
                                        r={(failed.has(i + 1) ? 2 : 0.75) * dot}
                                        className={
                                            failed.has(i + 1) ? 'builder_client-map__failed' : 'builder_client-map__wp'
                                        }
                                        strokeWidth={1.5 * px}
                                    />
                                ))}
                                {(l.route.stops ?? []).map(s => {
                                    const p = pts[s.at - 1];
                                    return p ? (
                                        <rect
                                            key={`s${s.at}`}
                                            x={sx(p) - dot * 1.6}
                                            y={sy(p) - dot * 1.6}
                                            width={dot * 3.2}
                                            height={dot * 3.2}
                                            className="builder_client-map__stop"
                                            strokeWidth={px}
                                        />
                                    ) : null;
                                })}
                                {pts.length ? (
                                    <circle
                                        cx={sx(pts[0])}
                                        cy={sy(pts[0])}
                                        r={dot * 1.8}
                                        className="builder_client-map__route-start"
                                        strokeWidth={1.5 * px}
                                    />
                                ) : null}
                                {(l.meta?.rejectedSamples ?? []).map((p, i) => (
                                    <g key={`r${i}`} className="builder_client-map__rejected" strokeWidth={1.4 * px}>
                                        <line x1={sx(p) - dot} y1={sy(p) - dot} x2={sx(p) + dot} y2={sy(p) + dot} />
                                        <line x1={sx(p) - dot} y1={sy(p) + dot} x2={sx(p) + dot} y2={sy(p) - dot} />
                                    </g>
                                ))}
                            </g>
                        );
                    }
                    if (l.lists) {
                        return (
                            <g key={l.spec.key} style={style}>
                                {l.lists.map((list, i) => (
                                    <g key={i}>
                                        <polyline
                                            points={polyline(list)}
                                            className="builder_client-map__path"
                                            strokeWidth={2 * px}
                                            strokeDasharray={`${4 * px} ${3 * px}`}
                                        />
                                        {list.map((p, k) => (
                                            <circle
                                                key={k}
                                                cx={sx(p)}
                                                cy={sy(p)}
                                                r={dot}
                                                className="builder_client-map__pt"
                                            />
                                        ))}
                                    </g>
                                ))}
                            </g>
                        );
                    }
                    return (
                        <g key={l.spec.key} style={style}>
                            {l.pts.map((p: Vec, i) => {
                                const w = (p as { w?: number }).w;
                                const r = (typeof w === 'number' ? w : 0) * (Math.PI / 180);
                                return (
                                    <g key={i}>
                                        {l.spec.kind === 'marker' && l.spec.radius ? (
                                            <circle
                                                cx={sx(p)}
                                                cy={sy(p)}
                                                r={l.spec.radius}
                                                className="builder_client-map__area"
                                                strokeWidth={1.2 * px}
                                            />
                                        ) : null}
                                        <circle cx={sx(p)} cy={sy(p)} r={dot} className="builder_client-map__pt" />
                                        {typeof w === 'number' ? (
                                            <line
                                                x1={sx(p)}
                                                y1={sy(p)}
                                                x2={sx(p) - Math.sin(r) * dot * 3}
                                                y2={sy(p) - Math.cos(r) * dot * 3}
                                                className="builder_client-map__heading"
                                                strokeWidth={1.4 * px}
                                            />
                                        ) : null}
                                    </g>
                                );
                            })}
                        </g>
                    );
                })}
            </svg>
            <div className="builder_client-map__scale cp-num">{t('builder.map.grid', { m: formatDistance(step) })}</div>
            {!start && !data.layers.some(l => l.pts.length) ? (
                <div className="builder_client-map__empty">{t('builder.map.empty')}</div>
            ) : null}
        </div>
    );
}
