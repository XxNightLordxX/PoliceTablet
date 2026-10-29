// "Locations": at least Config.Builder.minLocations locations, each with

import { useMemo, useState, useSyncExternalStore } from 'react';
import {
    Badge,
    Button,
    ConfirmDialog,
    EmptyState,
    Field,
    Icon,
    IconButton,
    NumberInput,
    Select,
    TextInput,
    type IconName,
} from '../../shared/components';
import { cx } from '../../shared/cx';
import { t } from '../../shared/i18n';
import { clientAction } from '../../shared/nui';
import { toast } from '../../shared/toast';
import type { BuilderKerbSpot, BuilderLocation, BuilderRoute, Vec3 } from '../../types/builder_server';
import type { BuilderAutoPointsReply, BuilderTeleportRequest, PointSpec, RouteMeta } from '../../types/builder_client';
import { CountBadge, ErrorNotes } from '../controls';
import { dist2d, errorsAt, errorsUnder, isRoute, listsOf, pointsOf, routeLength } from '../defUtils';
import { KEY_COLOURS, LocationMap, PointList } from '../LocationMap';
import { pointListRows, type PointListRow } from '../pointList';
import {
    KERB_RULES,
    armedKeepOut,
    missionPointSpecs,
    rangeOf,
    searchCircleOf,
    startRadiusRange,
    type SearchCircle,
} from '../schema';
import { editorMemory, routeMetaOf, setEditorMemory, setRouteMeta, shiftRouteMeta, subscribeBuilder } from '../store';
import { startSpec } from '../useDraftEditor';
import { minLocationsFor, StepIntro, type StepProps } from './common';

const KIND_ICON: Record<string, IconName> = {
    ped: 'user',
    vehicle: 'car',
    marker: 'mapPin',
    area: 'circle',
    start: 'flag',
    route: 'navigation',
};

function useStoreVersion(): number {
    return useSyncExternalStore(
        subscribeBuilder,
        () => storeTick(),
        () => 0,
    );
}
let tick = 0;
subscribeBuilder(() => {
    tick += 1;
});
function storeTick() {
    return tick;
}

function locationProgress(loc: BuilderLocation, specs: PointSpec[]): { done: number; total: number } {
    let done = loc.start ? 1 : 0;
    specs.forEach(s => {
        const v = loc[s.key];
        if (s.kind === 'route') {
            if ((isRoute(v) && v.points.length >= 2) || pointsOf(v).length >= s.min) done += 1;
        } else if (s.lists) {
            if (listsOf(v).length >= 1) done += 1;
        } else if (pointsOf(v).length >= Math.max(1, s.min)) done += 1;
    });
    return { done, total: specs.length + 1 };
}

// a hint, never an error: this many locations or more make a mission repeat less
const VARIETY_LOCATIONS = 3;

// "Fill N for me" fills keys of people or vehicles with many points that appear around a start (Config.Builder.autoFill)
function canAutoFill(spec: PointSpec): boolean {
    return spec.multiple && !spec.lists && !!spec.spawn && (spec.kind === 'ped' || spec.kind === 'vehicle');
}

export function StepLocations({ ed, cfg, def, ro, scope }: StepProps) {
    useStoreVersion();
    const [sel, setSel] = useState(() =>
        Math.min(Math.max(1, editorMemory(scope).location || 1), Math.max(1, def.locations.length)),
    );
    const [confirm, setConfirm] = useState<{ kind: 'removeLocation' } | { kind: 'clear'; spec: PointSpec } | null>(
        null,
    );
    const [focus, setFocus] = useState<string | null>(null);
    const [lit, setLit] = useState<{ key: string; index: number } | null>(null);
    // "Fill N for me": the proposal waiting for Keep / Try again / Place by hand (Config.Builder.autoFill)
    const [fill, setFill] = useState<{ key: string; li: number; reply: BuilderAutoPointsReply } | null>(null);
    const specs = useMemo(() => missionPointSpecs(cfg, def), [cfg, def]);
    const minLoc = minLocationsFor(cfg, ed.record?.overridesBuiltin);
    const maxLoc = Number(cfg.maxLocations) || 20;
    const li = Math.min(sel, Math.max(1, def.locations.length));
    const loc = def.locations[li - 1];
    // armed spawns stay outside this start's circle plus the margin: the ring the map and the legend show
    const armedMin = loc?.start && specs.some(s => s.armed) ? armedKeepOut(cfg, def, loc.start.radius) : null;
    const busy = ed.toolBusy || ro;
    const pick = (n: number) => {
        setSel(n);
        setLit(null);
        setFill(null);
        setEditorMemory(scope, { location: n });
    };
    const meta = (key: string) => routeMetaOf(ed.id, li, key);

    const addLocation = () => {
        const n = def.locations.length + 1;
        ed.update(d => {
            d.locations.push({ label: t('builder.location_default', { n }) });
        });
        pick(n);
    };
    const removeLocation = () => {
        const n = li;
        ed.update(d => {
            d.locations.splice(n - 1, 1);
        });
        shiftRouteMeta(ed.id, n);
        pick(Math.max(1, n - 1));
        setConfirm(null);
    };
    const clearKey = (spec: PointSpec) => {
        ed.update(d => {
            const l = d.locations[li - 1];
            if (spec.key === 'start') delete l.start;
            else delete l[spec.key];
        });
        setRouteMeta(ed.id, li, spec.key, null);
        setConfirm(null);
    };
    const rows = useMemo(() => (loc ? pointListRows(loc, specs) : []), [loc, specs]);
    const specOf = (row: PointListRow) => (row.specIndex >= 0 ? specs[row.specIndex] : startSpec());
    const hereAt = (row: PointListRow) => {
        const spec = specOf(row);
        // a recorded checkpoint route's points are placed as plain markers (as "Place points" does)
        const s = spec.kind === 'route' ? { ...spec, kind: 'marker' as const, heading: false } : spec;
        void ed.here(s, li, row.index);
    };
    const deleteAt = (row: PointListRow) => {
        if (row.key === 'start') {
            setConfirm({ kind: 'clear', spec: startSpec() });
            return;
        }
        setLit(null);
        void ed.removePoint(row.key, li, row.index).then(done => {
            if (done)
                toast('success', t('builder.loc.point_deleted', { label: t(specOf(row).labelKey), n: row.index }));
        });
    };
    const gps = async (c: Vec3) => {
        const res = await clientAction('builderWaypoint', { coords: c });
        toast(res.ok ? 'success' : 'error', t(res.ok ? 'builder.loc.gps_set' : (res.error ?? 'err.internal')));
    };
    // Teleport (Config.Builder.teleport, shown only when the server says this builder may): the server reads the
    // saved point, so unsaved changes are stored first
    const [jumping, setJumping] = useState(false);
    const teleport = async (key: string, index: number, label: string) => {
        if (jumping) return;
        setJumping(true);
        try {
            const missionId = !ro && ed.dirty ? await ed.flush() : ed.id;
            if (!missionId) return;
            const req: BuilderTeleportRequest = { missionId, location: li, key, index };
            const res = await clientAction('builderTeleport', req);
            toast(
                res.ok ? 'success' : 'error',
                res.ok ? t('builder.loc.teleported', { label }) : t(res.error ?? 'err.internal'),
            );
        } finally {
            setJumping(false);
        }
    };
    const teleportRow =
        cfg.teleport === true
            ? (row: PointListRow) =>
                  void teleport(
                      row.key,
                      row.index,
                      row.specIndex >= 0
                          ? t('builder.loc.point_n', { label: t(specs[row.specIndex].labelKey), n: row.index })
                          : t('builder.points.start'),
                  )
            : null;

    const fillHere = fill && fill.li === li ? fill : null;
    const runFill = async (spec: PointSpec, count: number) => {
        setFill(null);
        const reply = await ed.autoFill(spec, li, count);
        if (reply) setFill({ key: spec.key, li, reply });
    };
    const keepFill = async (spec: PointSpec) => {
        const f = fillHere;
        if (!f || f.key !== spec.key || !f.reply.result) return;
        setFill(null);
        if (await ed.keepFill(spec, f.reply.result))
            toast('success', t('builder.auto.kept', { n: f.reply.proposed.length }));
    };

    const topErrors = errorsAt(ed.errors, 'locations');
    return (
        <div className="builder_client-step">
            <StepIntro
                icon="mapPin"
                title={t('builder.loc.title')}
                aside={
                    <Badge size="sm" tone={def.locations.length >= minLoc ? 'success' : 'warning'}>
                        <span className="cp-num">
                            {t('builder.loc.count', { n: def.locations.length, min: minLoc })}
                        </span>
                    </Badge>
                }
            >
                {t('builder.loc.intro', {
                    min: minLoc,
                    gap: cfg.minLocationGap ?? 100,
                    spawn: cfg.minSpawnFromStart ?? 30,
                    margin: cfg.spawnMargin ?? 40,
                })}
            </StepIntro>
            <ErrorNotes errors={topErrors} />
            {def.locations.length >= minLoc && def.locations.length < VARIETY_LOCATIONS ? (
                <div className="builder_client-inline-note">
                    {t('builder.loc.variety_hint', { n: VARIETY_LOCATIONS })}
                </div>
            ) : null}
            <div className="builder_client-split">
                <nav className="builder_client-side" aria-label={t('builder.loc.list')}>
                    {def.locations.map((l, k) => {
                        const p = locationProgress(l, specs);
                        const n = errorsUnder(ed.errors, `locations.${k + 1}`).length;
                        return (
                            <button
                                key={k}
                                type="button"
                                className={cx('builder_client-side__item', li === k + 1 && 'is-active')}
                                onClick={() => pick(k + 1)}
                            >
                                <span className="builder_client-side__num cp-num">{k + 1}</span>
                                <span className="builder_client-side__text">
                                    <span className="builder_client-side__label">
                                        {l.label || t('builder.location_default', { n: k + 1 })}
                                    </span>
                                    <span className="builder_client-side__sub cp-num">
                                        {t('builder.loc.progress', { done: p.done, total: p.total })}
                                    </span>
                                </span>
                                {n ? (
                                    <Badge size="sm" tone="danger" icon="alert">
                                        <span className="cp-num">{n}</span>
                                    </Badge>
                                ) : p.done === p.total ? (
                                    <Icon name="checkCircle" size={15} className="builder_client-ok" />
                                ) : null}
                            </button>
                        );
                    })}
                    {!ro ? (
                        <Button
                            size="sm"
                            variant="secondary"
                            icon="plus"
                            block
                            disabled={def.locations.length >= maxLoc}
                            onClick={addLocation}
                        >
                            {t('builder.loc.add')}
                        </Button>
                    ) : null}
                </nav>
                <div className="builder_client-split__main">
                    {!loc ? (
                        <EmptyState
                            icon="mapPin"
                            title={t('builder.loc.none_title')}
                            text={t('builder.loc.none_text', { min: minLoc })}
                            action={
                                !ro ? (
                                    <Button variant="primary" icon="plus" onClick={addLocation}>
                                        {t('builder.loc.add')}
                                    </Button>
                                ) : undefined
                            }
                        />
                    ) : (
                        <>
                            <div className="builder_client-loc-head">
                                <Field
                                    label={t('builder.loc.name')}
                                    error={
                                        errorsAt(ed.errors, `locations.${li}.label`)
                                            .map(x => x.message)
                                            .join(' ') || undefined
                                    }
                                >
                                    <TextInput
                                        value={loc.label ?? ''}
                                        maxLength={cfg.limits?.locationLabel ?? 64}
                                        disabled={ro}
                                        onChange={v =>
                                            ed.update(d => {
                                                d.locations[li - 1].label = v.slice(0, cfg.limits?.locationLabel ?? 64);
                                            })
                                        }
                                    />
                                </Field>
                                {!ro ? (
                                    <IconButton
                                        icon="trash"
                                        label={t('builder.loc.remove')}
                                        variant="ghost"
                                        onClick={() => setConfirm({ kind: 'removeLocation' })}
                                    />
                                ) : null}
                            </div>
                            <LocationMap
                                location={loc}
                                specs={specs}
                                cfg={cfg}
                                meta={meta}
                                focusKey={focus}
                                height={230}
                                keepOut={armedMin}
                                highlight={lit}
                                proposed={fillHere ? fillHere.reply.proposed : null}
                            />
                            <PointList
                                rows={rows}
                                specs={specs}
                                lit={lit}
                                onLit={setLit}
                                onGps={c => void gps(c)}
                                onHere={cfg.useMyPosition !== false ? hereAt : null}
                                onTeleport={teleportRow}
                                teleporting={jumping || ed.toolBusy}
                                onDelete={deleteAt}
                                disabled={busy}
                                ro={ro}
                            />
                            <div className="builder_client-legend">
                                <span className="builder_client-legend__item">
                                    <span className="builder_client-legend__swatch is-start" />
                                    {t('builder.points.start')}
                                </span>
                                {specs.map((s, i) => (
                                    <button
                                        key={s.key}
                                        type="button"
                                        className={cx('builder_client-legend__item', focus === s.key && 'is-focus')}
                                        onMouseEnter={() => setFocus(s.key)}
                                        onMouseLeave={() => setFocus(null)}
                                        onFocus={() => setFocus(s.key)}
                                        onBlur={() => setFocus(null)}
                                    >
                                        <span
                                            className="builder_client-legend__swatch"
                                            style={{ background: KEY_COLOURS[i % KEY_COLOURS.length] }}
                                        />
                                        {t(s.labelKey)}
                                    </button>
                                ))}
                                {loc.start ? (
                                    <span className="builder_client-legend__item">
                                        <span className="builder_client-legend__swatch is-keepout" />
                                        {armedMin !== null
                                            ? t('builder.map.keepout_armed', { m: Math.round(armedMin) })
                                            : t('builder.map.keepout', { m: cfg.minSpawnFromStart ?? 30 })}
                                    </span>
                                ) : null}
                                <span className="builder_client-legend__item">
                                    <span className="builder_client-legend__swatch is-zone" />
                                    {t('builder.map.zone')}
                                </span>
                            </div>
                            <div className="builder_client-points">
                                <StartRow
                                    loc={loc}
                                    li={li}
                                    disabled={busy}
                                    onPlace={() => void ed.place(startSpec(), li)}
                                    onHere={cfg.useMyPosition !== false ? () => void ed.here(startSpec(), li) : null}
                                    onGps={gps}
                                    onTeleport={
                                        cfg.teleport === true
                                            ? () => void teleport('start', 1, t('builder.points.start'))
                                            : null
                                    }
                                    teleporting={jumping || ed.toolBusy}
                                    onClear={() => setConfirm({ kind: 'clear', spec: startSpec() })}
                                    errors={[
                                        ...errorsAt(ed.errors, `locations.${li}.start`),
                                        ...errorsAt(ed.errors, `locations.${li}.start.radius`),
                                        ...errorsAt(ed.errors, `locations.${li}`),
                                    ]}
                                    radiusRange={startRadiusRange(cfg, def)}
                                    search={searchCircleOf(cfg, def)}
                                    ro={ro}
                                    onRadius={r =>
                                        ed.update(d => {
                                            const s = d.locations[li - 1].start;
                                            if (s) s.radius = r;
                                        })
                                    }
                                />
                                {specs.map((s, i) => (
                                    <PointRow
                                        key={s.key}
                                        spec={s}
                                        colour={KEY_COLOURS[i % KEY_COLOURS.length]}
                                        loc={loc}
                                        li={li}
                                        ed={ed}
                                        cfg={cfg}
                                        armedMin={s.armed ? armedMin : null}
                                        meta={meta(s.key)}
                                        disabled={busy}
                                        ro={ro}
                                        onClear={() => setConfirm({ kind: 'clear', spec: s })}
                                        onFocus={setFocus}
                                        onFill={
                                            cfg.autoFill !== false && canAutoFill(s) ? n => void runFill(s, n) : null
                                        }
                                        proposal={fillHere && fillHere.key === s.key ? fillHere.reply : null}
                                        onKeep={() => void keepFill(s)}
                                        onDiscard={() => setFill(null)}
                                    />
                                ))}
                                {!specs.length ? (
                                    <div className="builder_client-muted">{t('builder.loc.no_points')}</div>
                                ) : null}
                            </div>
                        </>
                    )}
                </div>
            </div>
            <ConfirmDialog
                open={!!confirm}
                tone="danger"
                title={
                    confirm?.kind === 'removeLocation' ? t('builder.loc.remove_title') : t('builder.loc.clear_title')
                }
                message={
                    confirm?.kind === 'removeLocation'
                        ? t('builder.loc.remove_message', { label: loc?.label ?? '' })
                        : t('builder.loc.clear_message', {
                              label: confirm && confirm.kind === 'clear' ? t(confirm.spec.labelKey) : '',
                              location: li,
                          })
                }
                confirmLabel={confirm?.kind === 'removeLocation' ? t('builder.loc.remove') : t('builder.loc.clear')}
                onConfirm={() =>
                    confirm?.kind === 'removeLocation'
                        ? removeLocation()
                        : confirm && confirm.kind === 'clear'
                          ? clearKey(confirm.spec)
                          : undefined
                }
                onCancel={() => setConfirm(null)}
            />
        </div>
    );
}

function StartRow({
    loc,
    li,
    disabled,
    ro,
    onPlace,
    onHere,
    onGps,
    onTeleport,
    teleporting,
    onClear,
    errors,
    radiusRange,
    search,
    onRadius,
}: {
    loc: BuilderLocation;
    li: number;
    disabled: boolean;
    ro: boolean;
    onPlace: () => void;
    // "Set start here" (Config.Builder.useMyPosition), null when off
    onHere: (() => void) | null;
    onGps: (c: Vec3) => void;
    // Teleport to the start (Config.Builder.teleport and allowed for this builder), null when not
    onTeleport: (() => void) | null;
    teleporting: boolean;
    onClear: () => void;
    errors: ReturnType<typeof errorsAt>;
    radiusRange: [number, number, number];
    // the mission's search circle: the start radius is locked to it
    search: SearchCircle | null;
    onRadius: (r: number) => void;
}) {
    const s = loc.start;
    return (
        <div className={cx('builder_client-point', !s && 'is-missing')}>
            <div className="builder_client-point__icon is-start">
                <Icon name="flag" size={16} />
            </div>
            <div className="builder_client-point__body">
                <div className="builder_client-point__title">
                    <span>{t('builder.points.start')}</span>
                    {s ? (
                        <Badge size="sm" tone="success" icon="check">
                            {t('builder.loc.placed')}
                        </Badge>
                    ) : (
                        <Badge size="sm" tone="danger" icon="alert">
                            {t('builder.loc.not_placed')}
                        </Badge>
                    )}
                </div>
                <div className="builder_client-point__meta cp-num">
                    {s
                        ? t('builder.loc.start_meta', {
                              x: s.coords.x.toFixed(1),
                              y: s.coords.y.toFixed(1),
                              z: s.coords.z.toFixed(1),
                          })
                        : t('builder.loc.start_hint', { location: li })}
                </div>
                {s ? (
                    <div className="builder_client-inline-field">
                        <span>{t('builder.loc.start_radius')}</span>
                        <NumberInput
                            value={s.radius}
                            min={radiusRange[0]}
                            max={radiusRange[1]}
                            suffix={t('builder.unit.m')}
                            disabled={ro || !!search}
                            showRange={false}
                            onChange={v => v !== null && onRadius(v)}
                        />
                        {search ? (
                            <span className="builder_client-muted cp-num">
                                {t('builder.loc.start_radius_search', {
                                    n: search.objective,
                                    radius: search.radius,
                                    min: search.range.min,
                                    max: search.range.max,
                                })}
                            </span>
                        ) : (
                            <span className="builder_client-muted cp-num">
                                {t('builder.range', {
                                    min: radiusRange[0],
                                    max: radiusRange[1],
                                    unit: ` ${t('builder.unit.m')}`,
                                })}
                            </span>
                        )}
                    </div>
                ) : null}
                <ErrorNotes errors={errors} compact />
            </div>
            <div className="builder_client-point__actions">
                {s ? (
                    <IconButton
                        icon="navigation"
                        label={t('builder.loc.gps')}
                        variant="ghost"
                        size="sm"
                        onClick={() => onGps(s.coords)}
                    />
                ) : null}
                {s && onTeleport ? (
                    <Button
                        size="sm"
                        variant="ghost"
                        icon="zap"
                        onClick={onTeleport}
                        disabled={teleporting}
                        title={t('builder.loc.teleport_hint')}
                    >
                        {t('builder.loc.teleport')}
                    </Button>
                ) : null}
                {s && !ro ? (
                    <IconButton
                        icon="trash"
                        label={t('builder.loc.clear')}
                        variant="ghost"
                        size="sm"
                        onClick={onClear}
                        disabled={disabled}
                    />
                ) : null}
                {!ro && onHere ? (
                    <Button
                        size="sm"
                        variant="secondary"
                        icon="user"
                        onClick={onHere}
                        disabled={disabled}
                        title={t('builder.loc.here_hint')}
                    >
                        {t('builder.loc.start_here')}
                    </Button>
                ) : null}
                {!ro ? (
                    <Button size="sm" icon="mapPin" onClick={onPlace} disabled={disabled}>
                        {s ? t('builder.loc.move_start') : t('builder.loc.place_start')}
                    </Button>
                ) : null}
            </div>
        </div>
    );
}

function RouteChecks({
    route,
    cfg,
    meta,
    spec,
}: {
    route: BuilderRoute;
    cfg: StepProps['cfg'];
    meta: RouteMeta | null;
    spec: PointSpec;
}) {
    const r = cfg.route;
    const pts = route.points;
    const len = routeLength(pts);
    const lenOk = len >= r.minLength && len <= r.maxLength;
    const gap = pts.length > 1 ? dist2d(pts[0], pts[pts.length - 1]) : 0;
    const loop = route.loop === true || spec.loop;
    const endsOk = loop ? gap <= r.loopClose : gap >= r.minStartEndGap;
    const zoneHits = pts.filter(p => (cfg.noBuildZones ?? []).some(z => dist2d(p, z.coords) <= z.radius)).length;
    const items: { ok: boolean; text: string }[] = [
        {
            ok: lenOk,
            text: t('builder.route.length_check', {
                km: (len / 1000).toFixed(2),
                min: (r.minLength / 1000).toFixed(1),
                max: (r.maxLength / 1000).toFixed(1),
            }),
        },
        {
            ok: endsOk,
            text: loop
                ? t('builder.route.loop_check', { gap: Math.round(gap), max: r.loopClose })
                : t('builder.route.ends_check', { gap: Math.round(gap), min: r.minStartEndGap }),
        },
        {
            ok: zoneHits === 0,
            text: zoneHits ? t('builder.route.zone_bad', { n: zoneHits }) : t('builder.route.zone_ok'),
        },
    ];
    if (meta) {
        const un = meta.unreachable ?? [];
        items.push({
            ok: un.length === 0,
            text: un.length ? t('builder.route.unreachable', { list: un.join(', ') }) : t('builder.route.path_ok'),
        });
        if (meta.testedAt) {
            const f = meta.failed ?? [];
            items.push({
                ok: f.length === 0 && !!meta.completed,
                text: f.length
                    ? t('builder.route.drive_failed', { list: f.join(', '), s: r.testDriveTimeout })
                    : meta.completed
                      ? t('builder.route.drive_ok')
                      : t('builder.route.drive_stopped'),
            });
        }
    }
    return (
        <ul className="builder_client-checks-list">
            {items.map((it, i) => (
                <li key={i} className={it.ok ? 'is-ok' : 'is-bad'}>
                    <Icon name={it.ok ? 'checkCircle' : 'alert'} size={13} />
                    <span>{it.text}</span>
                </li>
            ))}
        </ul>
    );
}

function PointRow({
    spec,
    colour,
    loc,
    li,
    ed,
    cfg,
    armedMin,
    meta,
    disabled,
    ro,
    onClear,
    onFocus,
    onFill,
    proposal,
    onKeep,
    onDiscard,
}: {
    spec: PointSpec;
    colour: string;
    loc: BuilderLocation;
    li: number;
    ed: StepProps['ed'];
    cfg: StepProps['cfg'];
    // armed spawns: metres from the start (the start circle plus the margin), null when only the floor applies
    armedMin: number | null;
    meta: RouteMeta | null;
    disabled: boolean;
    ro: boolean;
    onClear: () => void;
    onFocus: (k: string | null) => void;
    // "Fill N for me" (Config.Builder.autoFill), null when this key cannot be filled
    onFill: ((count: number) => void) | null;
    // the proposal waiting for this key, null when none
    proposal: BuilderAutoPointsReply | null;
    onKeep: () => void;
    onDiscard: () => void;
}) {
    const v = loc[spec.key];
    const route = isRoute(v) ? v : null;
    const lists = spec.lists ? listsOf(v) : [];
    const have =
        spec.kind === 'route'
            ? route
                ? route.points.length
                : pointsOf(v).length
            : spec.lists
              ? lists.length
              : pointsOf(v).length;
    const need = spec.lists ? 1 : spec.kind === 'route' ? 2 : spec.min;
    const errs = errorsUnder(ed.errors, `locations.${li}.${spec.key}`);
    const needStart = spec.spawn && !loc.start;
    // "Fill N for me": the points still missing up to the key's least (never past its most)
    const fillCount = Math.max(0, Math.min(spec.min, spec.max) - have);
    const wait = rangeOf(cfg, 'escort', 'stopWait', [10, 60, 20]);
    const tags: string[] = [];
    if (spec.heading) tags.push(t('builder.loc.tag_heading'));
    if (armedMin !== null) tags.push(t('builder.loc.tag_armed', { m: Math.round(armedMin) }));
    else if (spec.spawn) tags.push(t('builder.loc.tag_spawn', { m: cfg.minSpawnFromStart ?? 30 }));
    if (spec.minGap) tags.push(t('builder.loc.tag_gap', { m: spec.minGap }));
    if (spec.stops) tags.push(t('builder.loc.tag_stops'));
    if (spec.loop) tags.push(t('builder.loc.tag_loop', { m: cfg.route?.loopClose ?? 50 }));
    if (spec.thinTo) tags.push(t('builder.loc.tag_thin', { n: spec.thinTo }));
    return (
        <div
            className={cx('builder_client-point', have < need && 'is-missing')}
            onMouseEnter={() => onFocus(spec.key)}
            onMouseLeave={() => onFocus(null)}
        >
            <div className="builder_client-point__icon" style={{ color: colour }}>
                <Icon name={KIND_ICON[spec.kind] ?? 'mapPin'} size={16} />
            </div>
            <div className="builder_client-point__body">
                <div className="builder_client-point__title">
                    <span>{t(spec.labelKey)}</span>
                    <span className="builder_client-mono builder_client-muted">{spec.key}</span>
                    <Badge size="sm" tone="grey" variant="outline">
                        {t('builder.loc.objective_n', { n: spec.objective })}
                    </Badge>
                    {spec.kind === 'route' ? (
                        route ? (
                            <Badge size="sm" tone="success" icon="check">
                                <span className="cp-num">
                                    {t('builder.loc.route_meta', {
                                        km: (routeLength(route.points) / 1000).toFixed(2),
                                        n: route.points.length,
                                    })}
                                </span>
                            </Badge>
                        ) : have >= need ? (
                            <CountBadge have={have} need={need} max={spec.max} />
                        ) : (
                            <Badge size="sm" tone="danger" icon="alert">
                                {t('builder.loc.not_recorded')}
                            </Badge>
                        )
                    ) : spec.lists ? (
                        <Badge size="sm" tone={have ? 'success' : 'danger'} icon={have ? 'check' : 'alert'}>
                            <span className="cp-num">{t('builder.loc.paths', { n: have })}</span>
                        </Badge>
                    ) : (
                        <CountBadge have={have} need={need} max={spec.max} />
                    )}
                </div>
                <div className="builder_client-point__meta">
                    {spec.kind === 'route'
                        ? t('builder.loc.route_hint')
                        : spec.lists
                          ? t('builder.loc.paths_hint')
                          : spec.multiple
                            ? t('builder.loc.multi_hint', { min: spec.min, max: spec.max })
                            : t('builder.loc.single_hint')}
                    {tags.length ? ` · ${tags.join(' · ')}` : ''}
                </div>
                {needStart && !ro ? (
                    <div className="builder_client-point__warn">
                        <Icon name="info" size={13} />
                        {t('builder.loc.start_first')}
                    </div>
                ) : null}
                {route ? (
                    <>
                        <RouteChecks route={route} cfg={cfg} meta={meta} spec={spec} />
                        {meta && (meta.rejected > 0 || meta.thinned || meta.droppedStops) ? (
                            <div className="builder_client-point__warn">
                                <Icon name="alert" size={13} />
                                {[
                                    meta.rejected
                                        ? t('builder.route.rejected', { n: meta.rejected, m: cfg.route.maxOffRoad })
                                        : '',
                                    meta.thinned
                                        ? t('builder.route.thinned', { from: meta.thinned, n: route.points.length })
                                        : '',
                                    meta.droppedStops ? t('builder.route.dropped_stops', { n: meta.droppedStops }) : '',
                                ]
                                    .filter(Boolean)
                                    .join(' · ')}
                            </div>
                        ) : null}
                        {spec.stops && (route.stops ?? []).length ? (
                            <div className="builder_client-stops">
                                {(route.stops ?? []).map((s, k) => (
                                    <div key={k} className="builder_client-stop">
                                        <span className="cp-num">
                                            {t('builder.route.stop_at', { n: k + 1, at: s.at })}
                                        </span>
                                        <NumberInput
                                            value={s.wait}
                                            min={wait.min}
                                            max={wait.max}
                                            suffix={t('builder.unit.s')}
                                            disabled={ro}
                                            showRange={false}
                                            onChange={n =>
                                                n !== null &&
                                                ed.update(d => {
                                                    const rv = d.locations[li - 1][spec.key];
                                                    if (isRoute(rv) && rv.stops && rv.stops[k]) rv.stops[k].wait = n;
                                                })
                                            }
                                        />
                                        {!ro ? (
                                            <IconButton
                                                icon="x"
                                                size="sm"
                                                variant="ghost"
                                                label={t('builder.route.stop_remove')}
                                                onClick={() =>
                                                    ed.update(d => {
                                                        const rv = d.locations[li - 1][spec.key];
                                                        if (isRoute(rv) && rv.stops) rv.stops.splice(k, 1);
                                                    })
                                                }
                                            />
                                        ) : null}
                                    </div>
                                ))}
                                <span className="builder_client-muted cp-num">
                                    {t('builder.route.stop_wait_range', { min: wait.min, max: wait.max })}
                                </span>
                            </div>
                        ) : null}
                    </>
                ) : null}
                {spec.ruled && Array.isArray(v) && v.length ? (
                    <div className="builder_client-kerb">
                        {(v as BuilderKerbSpot[]).map((spot, k) => (
                            <div key={k} className="builder_client-kerb__row">
                                <span className="cp-num">
                                    {t('builder.loc.kerb_n', { n: k + 1, street: spot.street || '—' })}
                                </span>
                                <Select
                                    value={spot.rule}
                                    disabled={ro}
                                    options={KERB_RULES.map(r => ({ value: r, label: t(`builder.fc.rule_${r}`) }))}
                                    onChange={r =>
                                        ed.update(d => {
                                            const cur = d.locations[li - 1][spec.key];
                                            if (Array.isArray(cur) && cur[k] && typeof cur[k] === 'object')
                                                (cur[k] as BuilderKerbSpot).rule = r;
                                        })
                                    }
                                />
                            </div>
                        ))}
                    </div>
                ) : null}
                {spec.lists && lists.length ? (
                    <div className="builder_client-paths">
                        {lists.map((l, k) => (
                            <span key={k} className="builder_client-path-chip">
                                <span className="cp-num">
                                    {t('builder.loc.path_n', { n: k + 1, points: l.length })}
                                </span>
                                {!ro ? (
                                    <button
                                        type="button"
                                        aria-label={t('builder.loc.path_remove')}
                                        onClick={() =>
                                            ed.update(d => {
                                                const cur = listsOf(d.locations[li - 1][spec.key]);
                                                cur.splice(k, 1);
                                                if (cur.length)
                                                    d.locations[li - 1][spec.key] = cur as unknown as Vec3[][];
                                                else delete d.locations[li - 1][spec.key];
                                            })
                                        }
                                    >
                                        <Icon name="x" size={11} />
                                    </button>
                                ) : null}
                            </span>
                        ))}
                    </div>
                ) : null}
                {proposal ? (
                    <div className="builder_client-fill">
                        <span className="builder_client-fill__text cp-num">
                            <Icon name="mapPin" size={13} />
                            {t('builder.auto.proposed', { n: proposal.proposed.length, want: proposal.wanted })}
                        </span>
                        <Button size="sm" variant="primary" icon="check" disabled={disabled} onClick={onKeep}>
                            {t('builder.auto.keep')}
                        </Button>
                        <Button
                            size="sm"
                            variant="secondary"
                            icon="refresh"
                            disabled={disabled || !onFill}
                            onClick={() => onFill?.(proposal.wanted)}
                        >
                            {t('builder.auto.again')}
                        </Button>
                        <Button
                            size="sm"
                            variant="ghost"
                            icon="mapPin"
                            disabled={disabled}
                            onClick={() => {
                                onDiscard();
                                void ed.place(spec, li);
                            }}
                        >
                            {t('builder.auto.by_hand')}
                        </Button>
                    </div>
                ) : null}
                <ErrorNotes errors={errs} compact />
            </div>
            {!ro ? (
                <div className="builder_client-point__actions">
                    {have > 0 ? (
                        <IconButton
                            icon="trash"
                            label={t('builder.loc.clear')}
                            variant="ghost"
                            size="sm"
                            onClick={onClear}
                            disabled={disabled}
                        />
                    ) : null}
                    {spec.kind === 'route' ? (
                        <>
                            {spec.placeable ? (
                                <Button
                                    size="sm"
                                    variant="primary"
                                    icon="mapPin"
                                    disabled={disabled}
                                    onClick={() =>
                                        void ed.place({ ...spec, kind: 'marker', multiple: true, heading: false }, li)
                                    }
                                >
                                    {t('builder.loc.place_points')}
                                </Button>
                            ) : null}
                            <Button
                                size="sm"
                                variant="secondary"
                                icon="car"
                                disabled={disabled || !route}
                                onClick={() => void ed.testDrive(spec, li)}
                            >
                                {t('builder.loc.test_drive')}
                            </Button>
                            <Button
                                size="sm"
                                icon="radio"
                                disabled={disabled}
                                onClick={() => void ed.recordRoute(spec, li)}
                            >
                                {route ? t('builder.loc.rerecord') : t('builder.loc.record')}
                            </Button>
                        </>
                    ) : (
                        <>
                            {onFill && !proposal && fillCount > 0 ? (
                                <Button
                                    size="sm"
                                    variant="secondary"
                                    icon="zap"
                                    disabled={disabled || needStart}
                                    title={t('builder.auto.hint')}
                                    onClick={() => onFill(fillCount)}
                                >
                                    {t('builder.auto.fill', { n: fillCount })}
                                </Button>
                            ) : null}
                            {cfg.useMyPosition !== false && !spec.lists ? (
                                <Button
                                    size="sm"
                                    variant="secondary"
                                    icon="user"
                                    disabled={disabled || needStart || (spec.multiple && have >= spec.max)}
                                    title={t('builder.loc.here_hint')}
                                    onClick={() => void ed.here(spec, li)}
                                >
                                    {spec.multiple ? t('builder.loc.add_here') : t('builder.loc.set_here')}
                                </Button>
                            ) : null}
                            <Button
                                size="sm"
                                icon="mapPin"
                                disabled={disabled || needStart}
                                onClick={() => void ed.place(spec, li)}
                            >
                                {spec.lists
                                    ? t('builder.loc.add_path')
                                    : have
                                      ? t('builder.loc.edit_points')
                                      : t('builder.loc.place')}
                            </Button>
                        </>
                    )}
                </div>
            ) : null}
        </div>
    );
}
