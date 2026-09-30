// The Rewards locker card on Home: item rewards that could not be given yet (offline, no room, Crimson-Arena).
// Hidden while it is empty. Claim asks the server, which checks everything again (server:rewards:claim).

import { Badge, Button, Card, Icon } from '../../shared/components';
import { fmtDateTime, formatNumber } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type { RewardRow, RewardsLocker as LockerView } from '../../types/rewards';
import './RewardsLocker.css';

export function sourceLabel(source: string): string {
    const key = `rewards.source.${source}`;
    return hasKey(key) ? t(key) : source;
}

export function statusLabel(status: string): string {
    const key = `rewards.status.${status}`;
    return hasKey(key) ? t(key) : status;
}

function LockerRow({
    row,
    canClaim,
    busy,
    onClaim,
}: {
    row: RewardRow;
    canClaim: boolean;
    busy: boolean;
    onClaim: (id: number) => void;
}) {
    const waiting = row.status === 'pending';
    return (
        <li className="rewards-locker__row">
            <span className="rewards-locker__icon" aria-hidden>
                <Icon name="gift" size={16} />
            </span>
            <div className="rewards-locker__text">
                <span className="rewards-locker__item">
                    {t('rewards.locker.item', { count: formatNumber(row.count), item: row.label })}
                </span>
                <span className="rewards-locker__meta">
                    {sourceLabel(row.source)} · {fmtDateTime(row.at)}
                </span>
            </div>
            {waiting ? (
                <Button
                    size="sm"
                    variant="primary"
                    icon="check"
                    disabled={!canClaim}
                    loading={busy}
                    onClick={() => onClaim(row.id)}
                >
                    {t('rewards.locker.claim')}
                </Button>
            ) : (
                <Badge size="sm" tone={row.status === 'held' ? 'warning' : 'neutral'}>
                    {statusLabel(row.status)}
                </Badge>
            )}
        </li>
    );
}

export function RewardsLocker() {
    const { data, refetch } = useRequest<LockerView>('getRewardsLocker', {}, { pushTopic: 'rewards' });
    const { run, busy } = useAction();
    const rows = data?.rows ?? [];
    if (rows.length === 0) return null;

    const claim = async (id: number) => {
        await run('server:rewards:claim', { id }, { success: 'rewards.locker.claimed' });
        void refetch();
    };
    const waiting = rows.filter(r => r.status === 'pending').length;

    return (
        <Card
            title={t('rewards.locker.title')}
            subtitle={t('rewards.locker.subtitle')}
            icon="gift"
            highlight="accent"
            padding="sm"
            actions={
                waiting > 0 ? (
                    <Badge tone="accent" size="sm">
                        {formatNumber(waiting)}
                    </Badge>
                ) : null
            }
            className="rewards-locker"
        >
            {!data?.canClaim && data?.reason ? (
                <p className="rewards-locker__reason" role="note">
                    {t(data.reason)}
                </p>
            ) : null}
            <ul className="rewards-locker__list">
                {rows.map(r => (
                    <LockerRow
                        key={r.id}
                        row={r}
                        canClaim={!!data?.canClaim}
                        busy={busy}
                        onClaim={id => void claim(id)}
                    />
                ))}
            </ul>
        </Card>
    );
}

export default RewardsLocker;
