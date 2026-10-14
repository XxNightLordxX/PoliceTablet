// Admin UI · Leaderboards → Item rewards (callback admin:getRewards): this week's totals, the configured pools and
// whether each item exists, rewards stuck while being given, and every reward, newest first, with filters and the
// admin actions (resolve a stuck one, deliver now, cancel, take back: ships off).

import { useMemo, useState } from 'react';
import {
    Badge,
    Button,
    Card,
    ConfirmDialog,
    EmptyState,
    ErrorState,
    Field,
    IconButton,
    KeyValue,
    LoadingBlock,
    Row,
    Select,
    Stat,
    Table,
    type BadgeTone,
    type TableColumn,
} from '../../shared/components';
import { fmtDateTime, formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { sourceLabel, statusLabel } from '../../officer/components/RewardsLocker';
import type { AdminRewardsView, RewardInventoryCheck, RewardRow } from '../../types/rewards';
import { DateRangeField, OfficerPicker, useAdminAction } from './kit';
import type { DateRange } from './kit';
import './ItemRewardsPanel.css';

type RewardAction = 'resolve' | 'deliver' | 'cancel' | 'takeBack';

const STATUSES = ['held', 'pending', 'giving', 'given', 'forfeited'];
const SOURCES = ['run', 'medal', 'goal', 'level', 'boss', 'season'];

function dayStart(day: string, next = false): number | undefined {
    if (!day) return undefined;
    const d = new Date(`${day}T00:00:00`);
    if (isNaN(d.getTime())) return undefined;
    if (next) d.setDate(d.getDate() + 1);
    return Math.floor(d.getTime() / 1000);
}

function actionsOf(r: RewardRow, view: AdminRewardsView): RewardAction[] {
    const out: RewardAction[] = [];
    if (r.status === 'giving') out.push('resolve');
    if (r.status === 'pending' && r.online) out.push('deliver');
    if (r.status === 'pending' || r.status === 'held') out.push('cancel');
    if (r.status === 'given' && r.online && view.allowTakeBack) out.push('takeBack');
    return out;
}

// What the inventory says about a stuck reward, then given (the default) or back to the locker (typed LOCKER).
function ResolveReward({ row, onClose, onDone }: { row: RewardRow; onClose: () => void; onDone: () => void }) {
    const { data } = useRequest<RewardInventoryCheck>('admin:checkRewardInventory', { id: row.id });
    const [outcome, setOutcome] = useState<'given' | 'locker'>('given');
    const { run } = useAdminAction();
    const found = data?.found === true;
    const confirm = async (reason: string, typed: string) => {
        const res = await run(
            'server:admin:resolveReward',
            { id: row.id, outcome, reason, confirm: typed },
            { requestId: false, success: 'admin.rewards.resolved' },
        );
        if (res.ok) onDone();
    };
    return (
        <ConfirmDialog
            open
            title={t('admin.rewards.resolve_title', { item: row.label })}
            message={
                !data
                    ? t('common.loading')
                    : !data.online
                      ? t('admin.rewards.resolve_offline')
                      : found
                        ? t('admin.rewards.resolve_found', { count: data.count ?? 0 })
                        : t('admin.rewards.resolve_not_found')
            }
            effect={
                data && data.online && !found ? (
                    <Field label={t('admin.rewards.resolve_outcome')}>
                        <Select
                            value={outcome}
                            onChange={v => setOutcome(v === 'locker' ? 'locker' : 'given')}
                            options={[
                                { value: 'given', label: t('admin.rewards.outcome_given') },
                                { value: 'locker', label: t('admin.rewards.outcome_locker') },
                            ]}
                        />
                    </Field>
                ) : data ? (
                    <KeyValue label={t('admin.rewards.col.item')}>
                        {t('rewards.locker.item', { count: formatNumber(data.needed), item: data.label })}
                    </KeyValue>
                ) : null
            }
            typedWord={outcome === 'locker' && !found ? 'LOCKER' : undefined}
            reason={{ required: true, maxLength: 255 }}
            onConfirm={async (reason, typed) => {
                if (!data || !data.online) return onClose();
                await confirm(reason, typed);
            }}
            onCancel={onClose}
        />
    );
}

const STATUS_TONE: Record<string, BadgeTone> = {
    given: 'success',
    pending: 'accent',
    held: 'warning',
    giving: 'danger',
    forfeited: 'neutral',
};

function rewardColumns(): TableColumn<RewardRow>[] {
    return [
        { key: 'at', header: t('admin.rewards.col.when'), width: 170, render: r => fmtDateTime(r.at) },
        {
            key: 'officer',
            header: t('admin.rewards.col.officer'),
            render: r => (
                <span className="rewards-admin__officer">
                    <span>{r.name ?? r.citizenid ?? '–'}</span>
                    {r.name && r.citizenid ? <code className="cp-selectable">{r.citizenid}</code> : null}
                </span>
            ),
        },
        {
            key: 'item',
            header: t('admin.rewards.col.item'),
            render: r => t('rewards.locker.item', { count: formatNumber(r.count), item: r.label }),
        },
        { key: 'source', header: t('admin.rewards.col.source'), width: 130, render: r => sourceLabel(r.source) },
        {
            key: 'status',
            header: t('admin.rewards.col.status'),
            width: 120,
            render: r => (
                <Badge size="sm" tone={STATUS_TONE[r.status] ?? 'neutral'}>
                    {statusLabel(r.status)}
                </Badge>
            ),
        },
    ];
}

function PoolsCard({ pools }: { pools: AdminRewardsView['pools'] }) {
    return (
        <Card title={t('admin.rewards.pools_title')} subtitle={t('admin.rewards.pools_hint')} icon="list" padding="sm">
            {pools.length === 0 ? (
                <EmptyState compact title={t('admin.rewards.pools_empty')} icon="gift" />
            ) : (
                <ul className="rewards-admin__pools">
                    {pools.map(p => (
                        <li key={p.key} className="rewards-admin__pool">
                            <code className="rewards-admin__pool-key">{p.key}</code>
                            <span className="rewards-admin__pool-items">
                                {p.items.map((it, i) => (
                                    <Badge
                                        key={`${it.item}-${i}`}
                                        size="sm"
                                        tone={it.ok ? 'success' : 'danger'}
                                        icon={it.ok ? 'check' : 'alert'}
                                        title={it.ok ? t('admin.rewards.item_ok') : t('admin.rewards.item_off')}
                                    >
                                        {it.item}
                                    </Badge>
                                ))}
                            </span>
                        </li>
                    ))}
                </ul>
            )}
        </Card>
    );
}

export function ItemRewardsPanel() {
    const [page, setPage] = useState(1);
    const [citizenid, setCitizenid] = useState<string | null>(null);
    const [status, setStatus] = useState('');
    const [source, setSource] = useState('');
    const [range, setRange] = useState<DateRange>({ from: '', to: '' });
    const [acting, setActing] = useState<{ row: RewardRow; kind: RewardAction } | null>(null);
    const { run } = useAdminAction();
    const args = useMemo(() => {
        const a: Record<string, unknown> = { page };
        if (citizenid) a.citizenid = citizenid;
        if (status) a.status = status;
        if (source) a.source = source;
        const from = dayStart(range.from);
        const to = dayStart(range.to, true);
        if (from !== undefined) a.from = from;
        if (to !== undefined) a.to = to;
        return a;
    }, [page, citizenid, status, source, range]);
    const { data, loading, error, refetch } = useRequest<AdminRewardsView>('admin:getRewards', args);
    const pick =
        <T,>(set: (v: T) => void) =>
        (v: T) => {
            set(v);
            setPage(1);
        };
    const columns: TableColumn<RewardRow>[] = [
        ...rewardColumns(),
        {
            key: 'actions',
            header: '',
            align: 'right',
            render: r =>
                data ? (
                    <span className="rewards-admin__actions">
                        {actionsOf(r, data).map(a => (
                            <IconButton
                                key={a}
                                size="sm"
                                variant="ghost"
                                icon={
                                    a === 'resolve'
                                        ? 'search'
                                        : a === 'deliver'
                                          ? 'gift'
                                          : a === 'cancel'
                                            ? 'x'
                                            : 'undo'
                                }
                                label={t(`admin.rewards.action.${a}`)}
                                onClick={() => setActing({ row: r, kind: a })}
                            />
                        ))}
                    </span>
                ) : null,
        },
    ];

    const act = async (reason: string, typed: string) => {
        if (!acting) return;
        const { row, kind } = acting;
        let res;
        if (kind === 'deliver') {
            res = await run('server:admin:deliverRewards', { citizenid: row.citizenid }, { requestId: false });
        } else if (kind === 'cancel') {
            res = await run('server:admin:cancelReward', { id: row.id, reason }, { requestId: false });
        } else {
            res = await run('server:admin:takeBackReward', { id: row.id, reason, confirm: typed });
        }
        if (res.ok) {
            setActing(null);
            void refetch();
        }
    };

    if (!data && loading) return <LoadingBlock />;
    if (!data && error) return <ErrorState error={error} onRetry={() => void refetch()} />;
    if (!data) return null;

    const pageSize = data.pageSize ?? 25;
    const recent = data.recent ?? [];
    const health = data.health ?? [];

    return (
        <div className="rewards-admin">
            <Row gap={2} wrap className="rewards-admin__head">
                <Badge tone={data.enabled ? 'success' : 'neutral'} icon="gift">
                    {data.enabled ? t('admin.rewards.on') : t('admin.rewards.off')}
                </Badge>
                <span className="rewards-admin__hint">{t('admin.rewards.config_hint')}</span>
                <IconButton
                    icon="refresh"
                    label={t('leaderboard.refresh')}
                    loading={loading}
                    onClick={() => void refetch()}
                />
            </Row>

            {health.length > 0 ? (
                <ul className="rewards-admin__health">
                    {health.map((h, i) => (
                        <li key={i} className={`rewards-admin__health-line rewards-admin__health-line--${h.level}`}>
                            {h.text}
                        </li>
                    ))}
                </ul>
            ) : null}

            <div className="rewards-admin__stats">
                <Stat
                    size="sm"
                    label={t('admin.rewards.week_given')}
                    value={formatNumber(data.week.given)}
                    icon="gift"
                    tone="success"
                />
                <Stat
                    size="sm"
                    label={t('admin.rewards.week_held')}
                    value={formatNumber(data.week.held)}
                    icon="clock"
                    tone={data.week.held ? 'warning' : 'neutral'}
                />
                <Stat
                    size="sm"
                    label={t('admin.rewards.week_forfeited')}
                    value={formatNumber(data.week.forfeited)}
                    icon="x"
                />
                <Stat
                    size="sm"
                    label={t('admin.rewards.stuck_count')}
                    value={formatNumber(data.stuck.length)}
                    icon="alert"
                    tone={data.stuck.length ? 'warning' : 'neutral'}
                />
            </div>

            {data.stuck.length > 0 ? (
                <Card
                    title={t('admin.rewards.stuck_title')}
                    subtitle={t('admin.rewards.stuck_hint')}
                    icon="alert"
                    highlight="warning"
                    padding="sm"
                >
                    <Table columns={columns} rows={data.stuck} dense aria-label={t('admin.rewards.stuck_title')} />
                </Card>
            ) : null}

            <PoolsCard pools={data.pools} />

            <div className="rewards-admin__filters">
                <Field label={t('admin.rewards.col.officer')}>
                    <OfficerPicker value={citizenid} onChange={c => pick(setCitizenid)(c)} />
                </Field>
                <Field label={t('admin.rewards.col.status')}>
                    <Select
                        value={status}
                        onChange={pick(setStatus)}
                        options={[
                            { value: '', label: t('admin.rewards.filter_all') },
                            ...STATUSES.map(s => ({ value: s, label: statusLabel(s) })),
                        ]}
                    />
                </Field>
                <Field label={t('admin.rewards.col.source')}>
                    <Select
                        value={source}
                        onChange={pick(setSource)}
                        options={[
                            { value: '', label: t('admin.rewards.filter_all') },
                            ...SOURCES.map(s => ({ value: s, label: sourceLabel(s) })),
                        ]}
                    />
                </Field>
                <DateRangeField value={range} onChange={pick(setRange)} />
            </div>

            <Card title={t('admin.rewards.recent_title')} icon="list" padding="sm">
                <Table
                    columns={columns}
                    rows={recent}
                    dense
                    empty={t('admin.rewards.recent_empty')}
                    aria-label={t('admin.rewards.recent_title')}
                />
                <Row gap={2} className="rewards-admin__pager">
                    <Button size="sm" icon="chevronLeft" disabled={page <= 1} onClick={() => setPage(p => p - 1)}>
                        {t('admin.rewards.newer')}
                    </Button>
                    <span className="rewards-admin__hint">{t('admin.rewards.page', { n: page })}</span>
                    <Button
                        size="sm"
                        iconRight="chevronRight"
                        disabled={recent.length < pageSize}
                        onClick={() => setPage(p => p + 1)}
                    >
                        {t('admin.rewards.older')}
                    </Button>
                </Row>
            </Card>
            {acting && acting.kind === 'resolve' ? (
                <ResolveReward
                    row={acting.row}
                    onClose={() => setActing(null)}
                    onDone={() => {
                        setActing(null);
                        void refetch();
                    }}
                />
            ) : null}
            <ConfirmDialog
                open={!!acting && acting.kind !== 'resolve'}
                title={acting ? t(`admin.rewards.action.${acting.kind}`) : ''}
                message={
                    acting
                        ? t(`admin.rewards.action_msg.${acting.kind}`, {
                              item: acting.row.label,
                              name: acting.row.name ?? acting.row.citizenid ?? '',
                          })
                        : ''
                }
                typedWord={acting?.kind === 'takeBack' ? acting.row.item : undefined}
                tone={acting?.kind === 'deliver' ? 'primary' : 'danger'}
                reason={acting?.kind === 'deliver' ? undefined : { required: true, maxLength: 255 }}
                onConfirm={act}
                onCancel={() => setActing(null)}
            />
        </div>
    );
}

export default ItemRewardsPanel;
