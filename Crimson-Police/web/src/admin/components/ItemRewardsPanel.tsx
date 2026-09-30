// Admin UI · Leaderboards → Item rewards (callback admin:getRewards): this week's totals, the configured pools and
// whether each item exists, rewards stuck while being given, and every reward, newest first.

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    EmptyState,
    ErrorState,
    IconButton,
    LoadingBlock,
    Row,
    Stat,
    Table,
    type BadgeTone,
    type TableColumn,
} from '../../shared/components';
import { fmtDateTime, formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { sourceLabel, statusLabel } from '../../officer/components/RewardsLocker';
import type { AdminRewardsView, RewardRow } from '../../types/rewards';
import './ItemRewardsPanel.css';

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
    const { data, loading, error, refetch } = useRequest<AdminRewardsView>('admin:getRewards', { page });
    const columns = rewardColumns();

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
        </div>
    );
}

export default ItemRewardsPanel;
