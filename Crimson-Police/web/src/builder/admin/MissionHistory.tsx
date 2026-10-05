// Admin UI → Missions: the load result, operation and dispatch history, mission stats, the Deleted list and the
// location switches that no longer match. All read-only except Bring back and Remap.

import { useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Dialog,
    EmptyState,
    Grid,
    Icon,
    LoadingBlock,
    SegmentedControl,
    Select,
    Stat,
    Table,
    TextInput,
    type TableColumn,
} from '../../shared/components';
import { formatDateTime, formatDuration, formatMoney } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { DateRangeField, Pager, useAdminAction, type DateRange } from '../../admin/components/kit';
import { BulkVoidDialog } from '../../admin/components/BulkVoidDialog';
import type {
    DeletedMission,
    DispatchHistoryRow,
    MissionLoadSummary,
    MissionStatsData,
    MissionStatsRow,
    OperationHistoryRow,
    Paged,
    SwitchRemapData,
    SwitchRemapMission,
} from '../../types/admin_missions';

function isoDay(ts: number): string {
    const d = new Date(ts * 1000);
    const p = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

// from = the first day's start, to = the start of the day after the last (never BETWEEN on the server)
function rangeArgs(r: DateRange): { from?: number; to?: number } {
    const out: { from?: number; to?: number } = {};
    if (r.from) out.from = Math.floor(new Date(`${r.from}T00:00:00`).getTime() / 1000);
    if (r.to) out.to = Math.floor(new Date(`${r.to}T00:00:00`).getTime() / 1000) + 86400;
    return out;
}

function defaultRange(days: number): DateRange {
    const now = Math.floor(Date.now() / 1000);
    return { from: isoDay(now - (days - 1) * 86400), to: isoDay(now) };
}

// ============================================================================
//                               THE LOAD RESULT
// ============================================================================

export function LoadSummaryBody({ summary }: { summary: MissionLoadSummary }) {
    const failed = [...(summary.failed ?? []), ...(summary.overrideFailed ?? [])];
    const rejected = summary.builder?.rejected ?? [];
    const warnings = summary.warningTexts ?? [];
    return (
        <div className="builder_client-form">
            <Grid cols={4} gap={3}>
                <Stat label={t('admin.missions.sum.loaded')} value={summary.loaded} tone="success" size="sm" />
                <Stat label={t('admin.missions.sum.builtin')} value={summary.builtin} size="sm" />
                <Stat label={t('admin.missions.sum.custom')} value={summary.custom} size="sm" />
                <Stat
                    label={t('admin.missions.sum.warnings')}
                    value={summary.warnings}
                    tone={summary.warnings ? 'warning' : 'neutral'}
                    size="sm"
                />
            </Grid>
            {summary.at ? (
                <div className="admin-missions-muted">
                    {t('admin.missions.load.at', { time: formatDateTime(summary.at) })}
                </div>
            ) : null}
            {summary.error ? (
                <div className="builder_client-callout builder_client-callout--warning">
                    <Icon name="alert" size={15} />
                    <span>{summary.error}</span>
                </div>
            ) : null}
            {failed.length ? (
                <ul className="builder_client-errors">
                    {failed.map(f => (
                        <li key={`${f.id}:${f.file ?? ''}`}>
                            <Icon name="xCircle" size={13} />
                            <span>
                                <b>{f.id}</b>
                                {f.file ? ` (${f.file})` : ''}: {f.error}
                            </span>
                        </li>
                    ))}
                </ul>
            ) : (
                <div className="builder_client-inline-note is-ok">
                    <Icon name="checkCircle" size={15} />
                    <span>{t('admin.missions.reload_clean')}</span>
                </div>
            )}
            {summary.builder ? (
                <div className="admin-missions-muted">
                    {t('admin.missions.load.sync', {
                        checked: summary.builder.checked,
                        edited: summary.builder.edited.length,
                        rejected: rejected.length,
                    })}
                </div>
            ) : null}
            {rejected.length ? (
                <ul className="builder_client-errors is-compact">
                    {rejected.map(r => (
                        <li key={r.id}>
                            <Icon name="alert" size={13} />
                            <span>
                                {t('admin.missions.load.rejected', { id: r.id })}: {r.error}
                            </span>
                        </li>
                    ))}
                </ul>
            ) : null}
            {warnings.length ? (
                <details className="admin-missions-details">
                    <summary>{t('admin.missions.load.warning_list', { n: warnings.length })}</summary>
                    <ul className="builder_client-errors is-compact">
                        {warnings.map((w, i) => (
                            <li key={i}>
                                <Icon name="info" size={13} />
                                <span>
                                    <b>{w.id}</b>: {w.text}
                                </span>
                            </li>
                        ))}
                    </ul>
                </details>
            ) : null}
        </div>
    );
}

// A banner above the catalog when the last load rejected a mission (or an edited built-in).
export function LoadResultBanner() {
    const load = useRequest<MissionLoadSummary>('admin:getMissionLoad', {}, { pushTopic: 'builder', pollMs: 60000 });
    const [open, setOpen] = useState(false);
    const s = load.data;
    if (!s) return null;
    const bad = (s.failed?.length ?? 0) + (s.overrideFailed?.length ?? 0) + (s.builder?.rejected?.length ?? 0);
    if (!bad && !s.warnings) return null;
    return (
        <>
            <div className={bad ? 'builder_client-callout builder_client-callout--warning' : 'builder_client-callout'}>
                <Icon name={bad ? 'alert' : 'info'} size={15} />
                <span>
                    {bad
                        ? t('admin.missions.load.banner_bad', { n: bad })
                        : t('admin.missions.load.banner_warn', { n: s.warnings })}
                </span>
                <span className="cp-spacer" />
                <Button size="sm" variant="ghost" onClick={() => setOpen(true)}>
                    {t('admin.missions.load.details')}
                </Button>
            </div>
            <Dialog
                open={open}
                onClose={() => setOpen(false)}
                title={t('admin.missions.load.title')}
                size="md"
                footer={<Button onClick={() => setOpen(false)}>{t('common.close')}</Button>}
            >
                <LoadSummaryBody summary={s} />
            </Dialog>
        </>
    );
}

// ============================================================================
//                            OPERATION HISTORY (C6)
// ============================================================================

const OP_STATUSES = ['', 'completed', 'cancelled', 'running', 'waiting', 'joining'];

export function OperationHistory() {
    const [range, setRange] = useState<DateRange>(() => defaultRange(30));
    const [status, setStatus] = useState('');
    const [page, setPage] = useState(1);
    const [open, setOpen] = useState<OperationHistoryRow | null>(null);
    // Void this operation's rows: the bulk void dialog of Officers (P1) with the operation as the fixed filter
    const [voiding, setVoiding] = useState<OperationHistoryRow | null>(null);
    const args = { ...rangeArgs(range), status: status || undefined, page };
    const data = useRequest<Paged<OperationHistoryRow>>('admin:getOperations', args);
    const columns: TableColumn<OperationHistoryRow>[] = [
        { key: 'when', header: t('admin.missions.history.when'), width: 150, render: r => formatDateTime(r.createdAt) },
        { key: 'mission', header: t('admin.missions.col.mission'), render: r => r.missionLabel },
        { key: 'by', header: t('admin.missions.history.launched_by'), render: r => r.launchedByName ?? r.launchedBy },
        {
            key: 'status',
            header: t('admin.missions.col.status'),
            width: 120,
            render: r => (
                <Badge
                    size="sm"
                    tone={r.status === 'completed' ? 'success' : r.status === 'cancelled' ? 'grey' : 'primary'}
                >
                    {t(`admin.missions.history.op_${r.status}`)}
                </Badge>
            ),
        },
        {
            key: 'n',
            header: t('admin.missions.history.officers'),
            width: 90,
            numeric: true,
            render: r => r.participants.length,
        },
        { key: 'pts', header: t('admin.missions.history.points'), width: 90, numeric: true, render: r => r.points },
        {
            key: 'open',
            header: '',
            width: 90,
            align: 'right',
            render: r => (
                <Button size="sm" variant="ghost" icon="eye" onClick={() => setOpen(r)}>
                    {t('admin.missions.history.details')}
                </Button>
            ),
        },
    ];
    return (
        <Card
            title={t('admin.missions.history.ops_title')}
            subtitle={t('admin.missions.history.ops_sub')}
            icon="globe"
            padding="none"
        >
            <div className="admin-missions-filters">
                <DateRangeField value={range} onChange={r => (setRange(r), setPage(1))} />
                <Select
                    value={status}
                    onChange={v => (setStatus(v), setPage(1))}
                    options={OP_STATUSES.map(s => ({
                        value: s,
                        label: s ? t(`admin.missions.history.op_${s}`) : t('admin.missions.history.any_status'),
                    }))}
                />
            </div>
            {data.loading && !data.data ? (
                <LoadingBlock />
            ) : (
                <>
                    <Table
                        dense
                        columns={columns}
                        rows={data.data?.rows ?? []}
                        rowKey={r => r.id}
                        empty={t('admin.missions.history.none')}
                    />
                    <Pager page={data.data?.page ?? 1} pages={data.data?.pages ?? 1} onPage={setPage} />
                </>
            )}
            <Dialog
                open={!!open}
                onClose={() => setOpen(null)}
                size="md"
                title={open ? `${open.missionLabel} · #${open.id}` : ''}
                footer={
                    <>
                        <Button
                            variant="danger"
                            icon="trash"
                            disabled={!open}
                            onClick={() => {
                                setVoiding(open);
                                setOpen(null);
                            }}
                        >
                            {t('int.ui.void_operation')}
                        </Button>
                        <Button onClick={() => setOpen(null)}>{t('common.close')}</Button>
                    </>
                }
            >
                {open ? (
                    <div className="admin-missions-stack">
                        <Table
                            dense
                            rows={open.participants}
                            rowKey={(p, i) => `${p.citizenid}:${i}`}
                            columns={[
                                {
                                    key: 'name',
                                    header: t('admin.missions.history.officer'),
                                    render: p => p.name ?? p.citizenid,
                                },
                                {
                                    key: 'dept',
                                    header: t('admin.missions.history.department'),
                                    width: 90,
                                    render: p => p.department.toUpperCase(),
                                },
                                {
                                    key: 'state',
                                    header: t('admin.missions.col.status'),
                                    width: 110,
                                    render: p => p.state,
                                },
                                {
                                    key: 'pts',
                                    header: t('admin.missions.history.points'),
                                    width: 90,
                                    numeric: true,
                                    render: p => (p.voided ? <s>{p.points}</s> : p.points),
                                },
                            ]}
                        />
                    </div>
                ) : null}
            </Dialog>
            <BulkVoidDialog
                open={!!voiding}
                onClose={() => setVoiding(null)}
                initial={voiding ? { operationId: voiding.id, allTime: true } : undefined}
                name={voiding ? `${voiding.missionLabel} · #${voiding.id}` : undefined}
                onDone={() => void data.refetch()}
            />
        </Card>
    );
}

// ============================================================================
//                            DISPATCH HISTORY (C7)
// ============================================================================

const CALL_OUTCOMES = ['', 'completed', 'failed', 'abandoned', 'reopened', 'lapsed', 'withdrawn', 'open', 'claimed'];

export function DispatchHistory() {
    const [range, setRange] = useState<DateRange>(() => defaultRange(7));
    const [type, setType] = useState('');
    const [outcome, setOutcome] = useState('');
    const [issuer, setIssuer] = useState('');
    const [page, setPage] = useState(1);
    const args = {
        ...rangeArgs(range),
        type: type.trim() || undefined,
        outcome: outcome || undefined,
        issuer: issuer.trim() || undefined,
        page,
    };
    const data = useRequest<Paged<DispatchHistoryRow>>('admin:getMissionCalls', args);
    const columns: TableColumn<DispatchHistoryRow>[] = [
        { key: 'when', header: t('admin.missions.history.when'), width: 150, render: r => formatDateTime(r.createdAt) },
        {
            key: 'code',
            header: t('admin.missions.history.code'),
            width: 90,
            render: r => <span className="admin-missions-mono">{r.code}</span>,
        },
        { key: 'type', header: t('admin.missions.col.type'), render: r => r.typeLabel },
        {
            key: 'area',
            header: t('admin.missions.history.area'),
            render: r => r.areaLabel ?? t('admin.missions.history.county'),
        },
        {
            key: 'issuer',
            header: t('admin.missions.history.issuer'),
            render: r => (r.issuer ? (r.issuerName ?? r.issuer) : t('admin.missions.history.server')),
        },
        {
            key: 'claimed',
            header: t('admin.missions.history.claimed_by'),
            render: r => r.claimedName ?? r.claimedBy ?? '—',
        },
        {
            key: 'response',
            header: t('admin.missions.history.response'),
            width: 100,
            numeric: true,
            render: r => (typeof r.claimSeconds === 'number' ? formatDuration(r.claimSeconds) : '—'),
        },
        {
            key: 'outcome',
            header: t('admin.missions.history.outcome'),
            width: 130,
            render: r => (
                <span title={r.reason ?? undefined}>{t(`admin.missions.history.out_${r.outcome ?? r.status}`)}</span>
            ),
        },
    ];
    return (
        <Card
            title={t('admin.missions.history.calls_title')}
            subtitle={t('admin.missions.history.calls_sub')}
            icon="radio"
            padding="none"
        >
            <div className="admin-missions-filters">
                <DateRangeField value={range} onChange={r => (setRange(r), setPage(1))} />
                <TextInput
                    value={type}
                    onChange={v => (setType(v), setPage(1))}
                    placeholder={t('admin.missions.history.type_ph')}
                    maxLength={32}
                />
                <Select
                    value={outcome}
                    onChange={v => (setOutcome(v), setPage(1))}
                    options={CALL_OUTCOMES.map(o => ({
                        value: o,
                        label: o ? t(`admin.missions.history.out_${o}`) : t('admin.missions.history.any_outcome'),
                    }))}
                />
                <TextInput
                    value={issuer}
                    onChange={v => (setIssuer(v), setPage(1))}
                    placeholder={t('admin.missions.history.issuer_ph')}
                    maxLength={50}
                />
            </div>
            {data.loading && !data.data ? (
                <LoadingBlock />
            ) : (
                <>
                    <Table
                        dense
                        columns={columns}
                        rows={data.data?.rows ?? []}
                        rowKey={r => r.id}
                        empty={t('admin.missions.history.none')}
                    />
                    <Pager page={data.data?.page ?? 1} pages={data.data?.pages ?? 1} onPage={setPage} />
                </>
            )}
        </Card>
    );
}

// ============================================================================
//                              MISSION STATS (C8)
// ============================================================================

type StatsBy = 'missions' | 'types';
type StatsSort = 'runs' | 'completionRate' | 'failRate' | 'abandonRate' | 'avgPoints' | 'avgCash';

export function MissionStats() {
    const [range, setRange] = useState<DateRange>(() => defaultRange(30));
    const [by, setBy] = useState<StatsBy>('missions');
    const [sort, setSort] = useState<StatsSort>('runs');
    const data = useRequest<MissionStatsData>('admin:getMissionStats', rangeArgs(range));
    const rows = useMemo(() => {
        const list = [...(data.data?.[by] ?? [])];
        list.sort((a, b) => (b[sort] as number) - (a[sort] as number));
        return list;
    }, [data.data, by, sort]);
    const pct = (n: number) => `${n}%`;
    const columns: TableColumn<MissionStatsRow>[] = [
        {
            key: 'label',
            header: by === 'missions' ? t('admin.missions.col.mission') : t('admin.missions.col.type'),
            render: r => r.label,
        },
        { key: 'runs', header: t('admin.missions.stats.runs'), width: 70, numeric: true, render: r => r.runs },
        {
            key: 'cr',
            header: t('admin.missions.stats.completed'),
            width: 90,
            numeric: true,
            render: r => pct(r.completionRate),
        },
        { key: 'fr', header: t('admin.missions.stats.failed'), width: 80, numeric: true, render: r => pct(r.failRate) },
        {
            key: 'ar',
            header: t('admin.missions.stats.abandoned'),
            width: 90,
            numeric: true,
            render: r => pct(r.abandonRate),
        },
        {
            key: 'dur',
            header: t('admin.missions.stats.duration'),
            width: 120,
            numeric: true,
            render: r =>
                `${formatDuration(r.avgDuration)}${typeof r.durationShare === 'number' ? ` (${r.durationShare}%)` : ''}`,
        },
        { key: 'pts', header: t('admin.missions.stats.points'), width: 80, numeric: true, render: r => r.avgPoints },
        {
            key: 'cash',
            header: t('admin.missions.stats.cash'),
            width: 90,
            numeric: true,
            render: r => formatMoney(r.avgCash),
        },
        { key: 'fl', header: t('admin.missions.stats.flags'), width: 70, numeric: true, render: r => r.flags },
        { key: 'vo', header: t('admin.missions.stats.voids'), width: 70, numeric: true, render: r => r.voids },
    ];
    return (
        <Card
            title={t('admin.missions.stats.title')}
            subtitle={t('admin.missions.stats.sub')}
            icon="barChart"
            padding="none"
        >
            <div className="admin-missions-filters">
                <DateRangeField value={range} onChange={setRange} />
                <SegmentedControl<StatsBy>
                    size="sm"
                    value={by}
                    onChange={setBy}
                    items={[
                        { key: 'missions', label: t('admin.missions.stats.by_mission') },
                        { key: 'types', label: t('admin.missions.stats.by_type') },
                    ]}
                />
                <Select
                    value={sort}
                    onChange={v => setSort(v as StatsSort)}
                    options={(
                        ['runs', 'completionRate', 'failRate', 'abandonRate', 'avgPoints', 'avgCash'] as StatsSort[]
                    ).map(k => ({ value: k, label: t(`admin.missions.stats.sort_${k}`) }))}
                />
            </div>
            {data.loading && !data.data ? (
                <LoadingBlock />
            ) : data.error && !data.data ? (
                <EmptyState compact icon="alert" title={t(data.error)} />
            ) : (
                <Table dense columns={columns} rows={rows} rowKey={r => r.key} empty={t('admin.missions.stats.none')} />
            )}
        </Card>
    );
}

// ============================================================================
//                    DELETED MISSIONS AND THE SWITCH REMAP
// ============================================================================

export function DeletedMissions({ onChanged }: { onChanged: () => void }) {
    const data = useRequest<{ missions: DeletedMission[] }>('builder:deleted', {}, { pushTopic: 'builder' });
    const { run, busy } = useAdminAction();
    const [back, setBack] = useState<DeletedMission | null>(null);
    const bringBack = async (reason: string) => {
        if (!back) return;
        const res = await run(
            'server:builder:undeleteMission',
            { folder: back.folder, reason },
            { success: 'admin.missions.deleted.back_done', successVars: { mission: back.label } },
        );
        setBack(null);
        if (res.ok) {
            void data.refetch();
            onChanged();
        }
    };
    const list = data.data?.missions ?? [];
    return (
        <Card
            title={t('admin.missions.deleted.title')}
            subtitle={t('admin.missions.deleted.sub')}
            icon="trash"
            padding="none"
        >
            {data.loading && !data.data ? (
                <LoadingBlock />
            ) : !list.length ? (
                <EmptyState compact icon="inbox" title={t('admin.missions.deleted.none')} />
            ) : (
                <Table
                    dense
                    rows={list}
                    rowKey={r => r.folder}
                    columns={[
                        { key: 'label', header: t('admin.missions.col.mission'), render: r => r.label },
                        { key: 'id', header: 'ID', render: r => <span className="admin-missions-mono">{r.id}</span> },
                        {
                            key: 'when',
                            header: t('admin.missions.deleted.when'),
                            width: 150,
                            render: r => formatDateTime(r.deletedAt),
                        },
                        { key: 'by', header: t('admin.missions.deleted.by'), render: r => r.deletedBy ?? '—' },
                        { key: 'reason', header: t('admin.missions.reason'), render: r => r.reason ?? '—' },
                        {
                            key: 'back',
                            header: '',
                            width: 130,
                            align: 'right',
                            render: r => (
                                <Button size="sm" icon="undo" disabled={busy} onClick={() => setBack(r)}>
                                    {t('admin.missions.deleted.back')}
                                </Button>
                            ),
                        },
                    ]}
                />
            )}
            <ConfirmDialog
                open={!!back}
                title={t('admin.missions.deleted.back_title', { mission: back?.label ?? '' })}
                message={t('admin.missions.deleted.back_text')}
                confirmLabel={t('admin.missions.deleted.back')}
                reason={{ required: true }}
                onConfirm={bringBack}
                onCancel={() => setBack(null)}
                busy={busy}
            />
        </Card>
    );
}

function RemapRow({ m, onDone }: { m: SwitchRemapMission; onDone: () => void }) {
    const { run, busy } = useAdminAction();
    const [to, setTo] = useState<Record<string, string>>({});
    const save = async () => {
        const map = m.stale.map(s => ({ from: s, to: to[String(s)] ? Number(to[String(s)]) : false }));
        const res = await run(
            'server:admin:remapLocationSwitches',
            { missionId: m.id, map },
            { success: 'admin.missions.remap.done', successVars: { mission: m.label } },
        );
        if (res.ok) onDone();
    };
    return (
        <div className="admin-missions-remap">
            <b>{m.label}</b>
            {m.stale.map(s => (
                <div key={String(s)} className="admin-missions-remap__row">
                    <span className="admin-missions-mono">{String(s)}</span>
                    <Icon name="chevronRight" size={14} />
                    <Select
                        value={to[String(s)] ?? ''}
                        onChange={v => setTo(x => ({ ...x, [String(s)]: v }))}
                        options={[
                            { value: '', label: t('admin.missions.remap.drop') },
                            ...m.locations.map(l => ({ value: String(l.index), label: `#${l.index} ${l.label}` })),
                        ]}
                    />
                </div>
            ))}
            <Button size="sm" variant="primary" icon="check" disabled={busy} onClick={() => void save()}>
                {t('admin.missions.remap.button')}
            </Button>
        </div>
    );
}

// Location switches are saved by the location's label: after an edit renames or removes a location, the ones that
// match nothing are listed here with Remap.
export function SwitchRemapCard({ onChanged }: { onChanged: () => void }) {
    const data = useRequest<SwitchRemapData>('admin:getSwitchRemap', {}, { pushTopic: 'builder' });
    const list = data.data?.missions ?? [];
    if (!list.length) return null;
    const n = list.reduce((a, m) => a + m.stale.length, 0);
    return (
        <Card
            title={t('admin.missions.remap.title', { n })}
            subtitle={t('admin.missions.remap.sub')}
            icon="mapPin"
            highlight="warning"
        >
            <div className="admin-missions-stack">
                {list.map(m => (
                    <RemapRow
                        key={m.id}
                        m={m}
                        onDone={() => {
                            void data.refetch();
                            onChanged();
                        }}
                    />
                ))}
            </div>
        </Card>
    );
}
