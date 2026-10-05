// Mission calls for staff: the Supervisor UI's Live Missions panel and the Admin UI's Missions tab (withdraw,
// page a unit, create a call, today's calls), plus the Admin area coverage matrix and location plays.

import { useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    Countdown,
    Dialog,
    EmptyState,
    ErrorState,
    Field,
    IconButton,
    LoadingBlock,
    Select,
    Table,
} from '../../shared/components';
import type { TableColumn } from '../../shared/components';
import { asArray } from '../../shared/data';
import { fmtDateTime, formatDuration } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useSession } from '../../shared/session';
import { toast } from '../../shared/toast';
import type { AreaCoverage, LocationPlay, MissionCall, PageableUnit, SupCallsView } from '../../types/missioncalls';
import './MissionCallsPanel.css';

const POLL_MS = 15000;
const COUNTY = 'county';

type TodayRow = SupCallsView['today'][number];
type Staff = null | { kind: 'create' | 'page' };

function useCallableTypes(): { key: string; label: string }[] {
    const session = useSession();
    return asArray(session.config.missionTypes).filter(m => m.key !== 'training');
}

function useAreas(): { key: string; label: string }[] {
    const session = useSession();
    return asArray(session.config.dispatch?.areas);
}

// ============================================================================
//                                 STAFF DIALOG
// ============================================================================

function StaffDialog({
    staff,
    units,
    busy,
    onClose,
    onSubmit,
}: {
    staff: Staff;
    units: PageableUnit[];
    busy: boolean;
    onClose: () => void;
    onSubmit: (payload: { type: string; area: string | null; leaderSrc?: number }) => void;
}) {
    const types = useCallableTypes();
    const areas = useAreas();
    const [type, setType] = useState('');
    const [area, setArea] = useState(COUNTY);
    const [leader, setLeader] = useState('');
    const page = staff?.kind === 'page';
    const ready = type !== '' && (!page || leader !== '');
    return (
        <Dialog
            open={!!staff}
            onClose={onClose}
            title={page ? t('mc.staff.page_title') : t('mc.staff.create_title')}
            description={page ? t('mc.staff.page_text') : t('mc.staff.create_text')}
            size="sm"
            footer={
                <>
                    <Button variant="ghost" onClick={onClose}>
                        {t('common.cancel')}
                    </Button>
                    <Button
                        variant="primary"
                        icon={page ? 'bell' : 'plus'}
                        disabled={!ready || busy}
                        loading={busy}
                        onClick={() =>
                            onSubmit({
                                type,
                                area: area === COUNTY ? null : area,
                                leaderSrc: page ? Number(leader) : undefined,
                            })
                        }
                    >
                        {page ? t('mc.staff.page') : t('mc.staff.create')}
                    </Button>
                </>
            }
        >
            <div className="mc-panel__form">
                <Field label={t('mc.staff.type')}>
                    <Select
                        value={type}
                        onChange={setType}
                        placeholder={t('mc.staff.pick_type')}
                        options={types.map(m => ({ value: m.key, label: m.label }))}
                    />
                </Field>
                <Field label={t('mc.staff.area')}>
                    <Select
                        value={area}
                        onChange={setArea}
                        options={[
                            { value: COUNTY, label: t('mc.county_wide') },
                            ...areas.map(a => ({ value: a.key, label: a.label })),
                        ]}
                    />
                </Field>
                {page ? (
                    <Field label={t('mc.staff.unit')} hint={units.length ? undefined : t('mc.staff.no_units')}>
                        <Select
                            value={leader}
                            onChange={setLeader}
                            placeholder={t('mc.staff.pick_unit')}
                            options={units.map(u => ({
                                value: String(u.src),
                                label: t('mc.staff.unit_option', {
                                    callsign: u.callsign ?? u.name,
                                    department: u.departmentShort,
                                    size: u.size,
                                }),
                            }))}
                        />
                    </Field>
                ) : null}
            </div>
        </Dialog>
    );
}

// ============================================================================
//                                  THE PANEL
// ============================================================================

export default function MissionCallsPanel({ scope }: { scope: 'sup' | 'admin' }) {
    const { data, loading, error, refetch } = useRequest<SupCallsView>('sup:getMissionCalls', {}, { pollMs: POLL_MS });
    const { run, busy } = useAction();
    const [withdrawing, setWithdrawing] = useState<MissionCall | null>(null);
    const [staff, setStaff] = useState<Staff>(null);
    const [stamp, setStamp] = useState(0);
    // Post anyway: an admin posting during the wait between staff calls (with a reason; supervisors still wait)
    const [early, setEarly] = useState<{ type: string; area: string | null } | null>(null);
    const open = asArray(data?.open as MissionCall[] | undefined);
    const today = asArray(data?.today as TodayRow[] | undefined);
    const units = asArray(data?.units as PageableUnit[] | undefined);

    const reload = async () => {
        await refetch();
        setStamp(s => s + 1);
    };

    const withdraw = async (reason: string) => {
        if (!withdrawing) return;
        const res = await run(
            `server:${scope}:mcWithdraw`,
            { callId: withdrawing.id, reason },
            { success: 'mc.staff.withdrawn', successVars: { code: withdrawing.code } },
        );
        setWithdrawing(null);
        if (res.ok) void reload();
    };

    const submit = async (payload: { type: string; area: string | null; leaderSrc?: number }) => {
        const page = staff?.kind === 'page';
        const res = await run(page ? `server:${scope}:mcPage` : `server:${scope}:mcCreate`, payload, {
            success: page ? 'mc.staff.paged' : 'mc.staff.created',
            silent: !page && scope === 'admin',
        });
        if (res.ok) {
            setStaff(null);
            void reload();
        } else if (!page && scope === 'admin') {
            if (res.error === 'err.mc_staff_cooldown') setEarly({ type: payload.type, area: payload.area });
            else toast('error', t(res.error ?? 'err.internal'));
        }
    };

    const postEarly = async (reason: string) => {
        if (!early) return;
        const res = await run(
            'server:admin:mcCreate',
            { ...early, skipWait: true, reason },
            { success: 'mc.staff.created' },
        );
        setEarly(null);
        if (res.ok) {
            setStaff(null);
            void reload();
        }
    };

    const openColumns: TableColumn<MissionCall>[] = [
        { key: 'code', header: t('mc.col.code'), width: 90, render: c => <span className="cp-num">{c.code}</span> },
        { key: 'type', header: t('mc.col.type'), render: c => c.typeLabel },
        { key: 'area', header: t('mc.col.area'), render: c => c.area?.label ?? t('mc.county_wide') },
        {
            key: 'status',
            header: t('mc.col.status'),
            render: c => (
                <Badge size="sm" tone={c.status === 'claiming' ? 'warning' : 'primary'}>
                    {t(`mc.staff.status_${c.status === 'claiming' ? 'claiming' : 'open'}`)}
                </Badge>
            ),
        },
        {
            key: 'left',
            header: t('mc.col.left'),
            width: 90,
            render: c => <Countdown seconds={c.offerEndsIn} resetKey={stamp} />,
        },
        {
            key: 'actions',
            header: '',
            width: 120,
            align: 'right',
            render: c => (
                <Button
                    size="sm"
                    variant="secondary"
                    icon="x"
                    disabled={c.status !== 'ready' && c.status !== 'priority' && c.status !== 'locked'}
                    onClick={() => setWithdrawing(c)}
                >
                    {t('mc.staff.withdraw')}
                </Button>
            ),
        },
    ];

    const todayColumns: TableColumn<TodayRow>[] = [
        { key: 'code', header: t('mc.col.code'), width: 90, render: r => <span className="cp-num">{r.code}</span> },
        { key: 'type', header: t('mc.col.type'), render: r => r.type },
        { key: 'status', header: t('mc.col.status'), render: r => t(`mc.outcome.${r.outcome ?? r.status}`) },
        { key: 'by', header: t('mc.col.claimed_by'), render: r => r.claimedBy ?? '—' },
        { key: 'claimants', header: t('mc.col.claimants'), numeric: true, width: 80, render: r => r.claimants },
        {
            key: 'claimS',
            header: t('mc.col.time_to_claim'),
            width: 110,
            render: r => (r.claimS === null ? '—' : formatDuration(r.claimS)),
        },
        {
            key: 'responseS',
            header: t('mc.col.response'),
            width: 100,
            render: r => (r.responseS === null || r.responseS === undefined ? '—' : formatDuration(r.responseS)),
        },
    ];

    return (
        <Card
            title={t('mc.staff.title')}
            subtitle={t('mc.staff.subtitle')}
            icon="radio"
            padding="none"
            actions={
                <div className="mc-panel__actions">
                    <Button size="sm" variant="secondary" icon="bell" onClick={() => setStaff({ kind: 'page' })}>
                        {t('mc.staff.page')}
                    </Button>
                    <Button size="sm" variant="primary" icon="plus" onClick={() => setStaff({ kind: 'create' })}>
                        {t('mc.staff.create')}
                    </Button>
                    <IconButton icon="refresh" label={t('sup.refresh')} variant="ghost" onClick={() => void reload()} />
                </div>
            }
        >
            {loading && !data ? <LoadingBlock /> : null}
            {error && !data ? <ErrorState error={error} onRetry={() => void reload()} /> : null}
            {data ? (
                <>
                    <Table
                        dense
                        rows={open}
                        rowKey={c => c.id}
                        columns={openColumns}
                        empty={<EmptyState compact icon="radio" title={t('mc.staff.none_open')} />}
                    />
                    <div className="mc-panel__today">
                        <Table
                            dense
                            rows={today}
                            rowKey={(r, i) => `${r.code}-${i}`}
                            columns={todayColumns}
                            empty={t('mc.staff.none_today')}
                        />
                    </div>
                </>
            ) : null}
            <ConfirmDialog
                open={!!withdrawing}
                tone="danger"
                title={withdrawing ? t('mc.staff.withdraw_title', { code: withdrawing.code }) : ''}
                message={t('mc.staff.withdraw_text')}
                confirmLabel={t('mc.staff.withdraw')}
                reason={{ required: true, label: t('common.reason'), maxLength: 255 }}
                onConfirm={withdraw}
                onCancel={() => setWithdrawing(null)}
                busy={busy}
            />
            {staff ? (
                <StaffDialog staff={staff} units={units} busy={busy} onClose={() => setStaff(null)} onSubmit={submit} />
            ) : null}
            <ConfirmDialog
                open={!!early}
                title={t('mc.staff.early_title')}
                message={t('mc.staff.early_text')}
                confirmLabel={t('mc.staff.early_button')}
                reason={{ required: true, label: t('common.reason'), maxLength: 255 }}
                onConfirm={postEarly}
                onCancel={() => setEarly(null)}
                busy={busy}
            />
        </Card>
    );
}

// ============================================================================
//                         ADMIN: AREA COVERAGE MATRIX
// ============================================================================

export function AreaCoverageMatrix() {
    const { data, loading, error, refetch } = useRequest<AreaCoverage>('admin:getAreaCoverage', {});
    const session = useSession();
    const labels = useMemo(() => {
        const out: Record<string, string> = {};
        for (const m of asArray(session.config.missionTypes)) out[m.key] = m.label;
        return out;
    }, [session]);
    const areas = asArray(data?.areas);
    const types = asArray(data?.types);
    return (
        <Card title={t('mc.coverage.title')} subtitle={t('mc.coverage.subtitle')} icon="mapPin" padding="sm">
            {loading && !data ? <LoadingBlock /> : null}
            {error && !data ? <ErrorState error={error} onRetry={() => void refetch()} /> : null}
            {data ? (
                <div className="mc-coverage">
                    <table>
                        <thead>
                            <tr>
                                <th>{t('mc.col.type')}</th>
                                {areas.map(a => (
                                    <th key={a.key}>{a.label}</th>
                                ))}
                            </tr>
                        </thead>
                        <tbody>
                            {types.map(ty => (
                                <tr key={ty}>
                                    <td>{labels[ty] ?? ty}</td>
                                    {areas.map(a => {
                                        const c = data.cells?.[ty]?.[a.key] ?? { missions: 0, locations: 0 };
                                        const cls = c.missions === 0 ? 'is-empty' : c.missions < 2 ? 'is-thin' : '';
                                        return (
                                            <td key={a.key} className={cls}>
                                                {t('mc.coverage.cell', {
                                                    missions: c.missions,
                                                    locations: c.locations,
                                                })}
                                            </td>
                                        );
                                    })}
                                </tr>
                            ))}
                        </tbody>
                    </table>
                    <p className="mc-panel__muted">{t('mc.coverage.note')}</p>
                </div>
            ) : null}
        </Card>
    );
}

// ============================================================================
//                            ADMIN: LOCATION PLAYS
// ============================================================================

export function LocationPlays({ missions }: { missions: { id: string; label: string }[] }) {
    const [missionId, setMissionId] = useState('');
    const areas = useAreas();
    const areaLabel = (key: string | null) => areas.find(a => a.key === key)?.label ?? '—';
    const { data, loading, error, refetch } = useRequest<LocationPlay[]>(
        'admin:getLocationStats',
        { missionId },
        { skip: missionId === '' },
    );
    const rows = asArray(data as LocationPlay[] | null);
    return (
        <Card title={t('mc.plays.title')} subtitle={t('mc.plays.subtitle')} icon="barChart" padding="sm">
            <Field label={t('mc.plays.mission')}>
                <Select
                    value={missionId}
                    onChange={setMissionId}
                    placeholder={t('mc.plays.pick')}
                    options={missions.map(m => ({ value: m.id, label: m.label }))}
                />
            </Field>
            {missionId && loading && !data ? <LoadingBlock /> : null}
            {missionId && error ? <ErrorState error={error} onRetry={() => void refetch()} /> : null}
            {missionId && data ? (
                <Table
                    dense
                    rows={rows}
                    rowKey={r => r.index}
                    empty={t('mc.plays.none')}
                    columns={[
                        { key: 'index', header: '#', width: 50, render: r => r.index },
                        { key: 'label', header: t('mc.plays.location'), render: r => r.label },
                        { key: 'area', header: t('mc.col.area'), render: r => areaLabel(r.area) },
                        { key: 'plays', header: t('mc.plays.plays'), numeric: true, width: 80, render: r => r.plays },
                        {
                            key: 'last',
                            header: t('mc.plays.last'),
                            width: 160,
                            render: r => (r.lastPlayed ? fmtDateTime(r.lastPlayed) : '—'),
                        },
                    ]}
                />
            ) : null}
        </Card>
    );
}
