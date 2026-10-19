// Admin UI · Testing: the Check spawn points dialog (PLAN S8). The check itself is modules/testing/client.lua.

import { useEffect, useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Dialog,
    EmptyState,
    Field,
    Icon,
    IconButton,
    ProgressBar,
    SegmentedControl,
    Select,
    Stat,
    Toggle,
} from '../../shared/components';
import type { BadgeTone } from '../../shared/components';
import { cx } from '../../shared/cx';
import { t } from '../../shared/i18n';
import { clientAction } from '../../shared/nui';
import { toast } from '../../shared/toast';
import { asList, type SpawnCheckScope, type SpawnProbeStatus, type TestsView } from '../../types/testing';
import { copyLine } from './copyText';
import {
    isBad,
    spawnCheckReport,
    startSpawnCheck,
    stopSpawnCheck,
    useSpawnCheck,
    type SpawnCheckRow,
    type SpawnCheckStatus,
} from './spawnCheckStore';
import './SpawnCheckDialog.css';

type ScopeKind = 'all' | 'mission' | 'location';

const STATUS_TONE: Record<SpawnProbeStatus, BadgeTone> = {
    ok: 'success',
    snap: 'warning',
    underground: 'danger',
    floating: 'danger',
    no_ground: 'danger',
    in_water: 'danger',
    in_wall: 'danger',
    interior_not_loaded: 'warning',
    skipped: 'neutral',
};
const RUN_TONE: Record<SpawnCheckStatus, BadgeTone> = {
    idle: 'neutral',
    running: 'warning',
    done: 'success',
    stopped: 'neutral',
    failed: 'danger',
};
// rows drawn at once (a check of every mission has about 2200 points); the report always has every problem
const ROW_LIMIT = 300;

function fixed(v: unknown, places: number): string {
    return typeof v === 'number' && Number.isFinite(v) ? v.toFixed(places) : '—';
}

function signed(v: unknown): string {
    return typeof v === 'number' && Number.isFinite(v) ? `${v >= 0 ? '+' : ''}${v.toFixed(2)}` : '—';
}

function rowKey(r: SpawnCheckRow): string {
    return `${r.missionId}#${r.location}:${r.id}`;
}

function Notes({ r }: { r: SpawnCheckRow }) {
    const notes: string[] = [];
    asList(r.near).forEach(n => {
        if (n === 'start') notes.push(t('test.ui.spawn.near_start', { m: fixed(r.dStart, 1) }));
        if (n === 'previous') notes.push(t('test.ui.spawn.near_previous', { m: fixed(r.dPrevious, 1) }));
    });
    if (r.seen === true) notes.push(t('test.ui.spawn.seen'));
    if (!notes.length) return <span className="testing-muted">—</span>;
    return <span className="spawncheck-notes">{notes.join(' · ')}</span>;
}

export interface SpawnCheckPreset {
    missionId: string;
    location?: number;
}

interface Props {
    open: boolean;
    // opened from a location row: that location
    preset: SpawnCheckPreset | null;
    view: TestsView;
    // why a check cannot start now (an err.* key), e.g. the admin's own test run
    blocked: string | null;
    onClose: () => void;
}

export function SpawnCheckDialog({ open, preset, view, blocked, onClose }: Props) {
    const check = useSpawnCheck();
    const missions = asList(view.missions);
    const cfg = view.config.spawnCheck;
    const [scope, setScope] = useState<ScopeKind>('all');
    const [missionId, setMissionId] = useState('');
    const [location, setLocation] = useState('');
    const [problemsOnly, setProblemsOnly] = useState(true);
    const [starting, setStarting] = useState(false);
    const [moving, setMoving] = useState<string | null>(null);
    const running = check.status === 'running';

    useEffect(() => {
        if (!open || !preset) return;
        setMissionId(preset.missionId);
        setLocation(preset.location ? String(preset.location) : '');
        setScope(preset.location ? 'location' : 'mission');
    }, [open, preset]);

    const mission = missions.find(m => m.id === missionId) || null;
    const pickMission = (id: string) => {
        setMissionId(id);
        setLocation('');
    };

    const scopeOk = scope === 'all' || (!!mission && (scope === 'mission' || location !== ''));
    const canStart = !!cfg?.enabled && !running && !starting && !blocked && scopeOk;

    const start = async () => {
        const payload: SpawnCheckScope =
            scope === 'all' ? {} : scope === 'mission' ? { missionId } : { missionId, location: Number(location) };
        setStarting(true);
        const res = await startSpawnCheck(payload);
        setStarting(false);
        if (!res.ok) toast('error', t(res.error || 'err.internal'));
    };

    const stop = async () => {
        const res = await stopSpawnCheck();
        if (!res.ok) toast('error', t(res.error || 'err.internal'));
    };

    const teleport = async (r: SpawnCheckRow) => {
        setMoving(rowKey(r));
        const res = await clientAction('teleport', {
            target: 'point',
            missionId: r.missionId,
            location: r.location,
            point: r.id,
        });
        setMoving(null);
        if (!res.ok) toast('error', t(res.error || 'err.internal'));
        else toast('success', t('test.ui.spawn.teleported', { point: r.id }));
    };

    const badRows = useMemo(() => check.rows.filter(r => isBad(r.status)), [check.rows]);
    const listed = problemsOnly ? badRows : check.rows;
    const shown = listed.slice(0, ROW_LIMIT);
    const p = check.progress;
    const planned = check.planned ? check.planned.locations : 0;
    const done = Math.max(0, check.reached - 1) + (p && p.points > 0 ? p.point / p.points : 0);

    const locationOptions = asList(mission?.locations).map(l => ({
        value: String(l.index),
        label: `#${l.index} · ${l.label}`,
    }));

    return (
        <Dialog
            open={open}
            onClose={onClose}
            size="lg"
            className="spawncheck"
            title={t('test.ui.spawn.title')}
            description={t('test.ui.spawn.desc')}
            footer={
                <>
                    <Button
                        variant="ghost"
                        icon="fileText"
                        disabled={!check.rows.length && !check.skipped.length}
                        onClick={() => copyLine(spawnCheckReport(check))}
                    >
                        {t('test.ui.spawn.copy')}
                    </Button>
                    <Button onClick={onClose}>{t('common.close')}</Button>
                </>
            }
        >
            <div className="spawncheck__setup">
                <div className="spawncheck__top">
                    <SegmentedControl<ScopeKind>
                        size="sm"
                        value={scope}
                        onChange={setScope}
                        aria-label={t('test.ui.spawn.scope')}
                        items={[
                            { key: 'all', label: t('test.ui.spawn.scope_all') },
                            { key: 'mission', label: t('test.ui.spawn.scope_mission') },
                            { key: 'location', label: t('test.ui.spawn.scope_location') },
                        ]}
                    />
                    {running ? (
                        <Button variant="danger" icon="xCircle" onClick={stop} loading={check.stopping}>
                            {t(check.stopping ? 'test.ui.spawn.stopping' : 'test.ui.spawn.stop')}
                        </Button>
                    ) : (
                        <Button variant="primary" icon="mapPin" onClick={start} loading={starting} disabled={!canStart}>
                            {t('test.ui.spawn.start')}
                        </Button>
                    )}
                </div>
                {scope !== 'all' ? (
                    <div className="spawncheck__pick">
                        <Field label={t('test.ui.mission')}>
                            <Select
                                value={missionId}
                                onChange={pickMission}
                                placeholder={t('test.ui.spawn.pick_mission')}
                                options={missions.map(m => ({ value: m.id, label: `${m.label} · ${m.typeLabel}` }))}
                            />
                        </Field>
                        {scope === 'location' ? (
                            <Field label={t('test.ui.location')}>
                                <Select
                                    value={location}
                                    onChange={setLocation}
                                    placeholder={t('test.ui.spawn.pick_location')}
                                    options={locationOptions}
                                    disabled={!mission}
                                />
                            </Field>
                        ) : null}
                    </div>
                ) : null}
                <div className="spawncheck__notes">
                    <span>
                        <Icon name="info" size={14} />
                        {t('test.ui.spawn.how')}
                    </span>
                    {!cfg?.routes ? (
                        <span>
                            <Icon name="navigation" size={14} />
                            {t('test.ui.spawn.routes_off')}
                        </span>
                    ) : null}
                    {blocked ? (
                        <span className="is-warning">
                            <Icon name="alert" size={14} />
                            {t(blocked)}
                        </span>
                    ) : null}
                </div>
            </div>

            {check.status !== 'idle' ? (
                <div className="spawncheck__run">
                    <div className="spawncheck__state">
                        <Badge tone={RUN_TONE[check.status]} dot={running}>
                            {t(`test.ui.spawn.state_${check.status}`)}
                        </Badge>
                        {running && check.current ? (
                            <span className="spawncheck__where">
                                {t('test.ui.spawn.checking', {
                                    mission: check.current.missionLabel,
                                    n: check.current.location,
                                    location: check.current.locationLabel,
                                })}
                            </span>
                        ) : null}
                        {check.status === 'failed' && check.error ? (
                            <span className="spawncheck__error">{t(check.error)}</span>
                        ) : null}
                    </div>
                    {p ? (
                        <ProgressBar
                            size="sm"
                            tone={check.status === 'failed' ? 'danger' : badRows.length ? 'warning' : 'success'}
                            value={check.status === 'done' ? planned || 1 : done}
                            max={planned || 1}
                            label={t('test.ui.spawn.progress', {
                                mission: p.mission,
                                missions: p.missions,
                                location: p.location,
                                locations: p.locations,
                                point: p.point,
                                points: p.points,
                            })}
                        />
                    ) : null}
                    <div className="spawncheck__stats">
                        <Stat
                            size="sm"
                            icon="mapPin"
                            label={t('test.ui.spawn.stat_points')}
                            value={check.rows.length}
                        />
                        <Stat
                            size="sm"
                            icon="alert"
                            tone={badRows.length ? 'danger' : 'success'}
                            label={t('test.ui.spawn.stat_bad')}
                            value={badRows.length}
                        />
                        <Stat
                            size="sm"
                            icon="layers"
                            label={t('test.ui.spawn.stat_locations')}
                            value={check.reached}
                            hint={planned ? t('test.ui.spawn.stat_of', { n: planned }) : undefined}
                        />
                    </div>
                </div>
            ) : null}

            {check.rows.length ? (
                <div className="spawncheck__results">
                    <div className="spawncheck__results-head">
                        <span className="spawncheck__results-title">{t('test.ui.spawn.results')}</span>
                        <Toggle
                            checked={problemsOnly}
                            onChange={setProblemsOnly}
                            label={t('test.ui.spawn.problems_only')}
                        />
                    </div>
                    {!shown.length ? (
                        <EmptyState compact icon="checkCircle" title={t('test.ui.spawn.no_problems')} />
                    ) : (
                        <div className="cp-table-wrap spawncheck__table-wrap">
                            <table className="cp-table cp-table--dense" aria-label={t('test.ui.spawn.results')}>
                                <thead>
                                    <tr>
                                        <th>{t('test.ui.spawn.col_where')}</th>
                                        <th>{t('test.ui.spawn.col_kind')}</th>
                                        <th className="testing-num">{t('test.ui.spawn.col_xyz')}</th>
                                        <th className="testing-num">{t('test.ui.spawn.col_ground')}</th>
                                        <th>{t('test.ui.spawn.col_status')}</th>
                                        <th>{t('test.ui.spawn.col_notes')}</th>
                                        {cfg?.teleport ? <th aria-label={t('test.ui.spawn.teleport')} /> : null}
                                    </tr>
                                </thead>
                                <tbody>
                                    {shown.map(r => (
                                        <tr key={rowKey(r)} className={cx(isBad(r.status) && 'is-bad')}>
                                            <td
                                                className="spawncheck__where"
                                                title={`${r.missionLabel} · ${r.locationLabel}`}
                                            >
                                                <span className="spawncheck__mission">
                                                    {r.missionLabel} <span className="cp-num">#{r.location}</span>
                                                </span>
                                                <span className="spawncheck__id">{r.id}</span>
                                            </td>
                                            <td>{t(`test.ui.spawn.kind_${r.kind}`)}</td>
                                            <td className="testing-num cp-num">
                                                {fixed(r.x, 2)}, {fixed(r.y, 2)}, {fixed(r.z, 2)}
                                            </td>
                                            <td className="testing-num cp-num">
                                                {fixed(r.groundZ, 2)}{' '}
                                                <span className="testing-muted">({signed(r.dz)})</span>
                                            </td>
                                            <td>
                                                <Badge
                                                    size="sm"
                                                    tone={STATUS_TONE[r.status] ?? 'danger'}
                                                    title={t(`test.ui.spawn.hint_${r.status}`)}
                                                >
                                                    {t(`test.ui.spawn.status_${r.status}`)}
                                                </Badge>
                                            </td>
                                            <td>
                                                <Notes r={r} />
                                            </td>
                                            {cfg?.teleport ? (
                                                <td>
                                                    <IconButton
                                                        icon="navigation"
                                                        size="sm"
                                                        variant="ghost"
                                                        label={t('test.ui.spawn.teleport')}
                                                        disabled={running || moving !== null}
                                                        loading={moving === rowKey(r)}
                                                        onClick={() => void teleport(r)}
                                                    />
                                                </td>
                                            ) : null}
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </div>
                    )}
                    {listed.length > shown.length ? (
                        <div className="testing-muted spawncheck__more">
                            {t('test.ui.spawn.more', { n: shown.length, total: listed.length })}
                        </div>
                    ) : null}
                </div>
            ) : null}

            {check.skipped.length ? (
                <div className="spawncheck__skipped">
                    <span className="spawncheck__results-title">{t('test.ui.spawn.skipped')}</span>
                    <ul>
                        {check.skipped.map(s => (
                            <li key={`${s.missionId}#${s.location}`}>
                                {s.missionLabel} <span className="cp-num">#{s.location}</span>: {t(s.error)}
                            </li>
                        ))}
                    </ul>
                </div>
            ) : null}
        </Dialog>
    );
}
