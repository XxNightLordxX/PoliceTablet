// One run's history as one timeline (FIN4): the rows written, the flags and staff notes, every staff decision, the

// One run's history as one timeline (FIN4): the rows written, the flags and staff notes, every staff decision, the
// disputes and the correction batches, oldest first (modules/review/history.lua). RunHistoryList draws a list of
// events (the Admin UI's run detail hands its view.history); RunHistoryDialog asks review:getRunHistory for one run
// (the Review queue's History button).

import { Badge, Dialog, Button, LoadingBlock, ErrorState, type BadgeTone } from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatDateTime } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { hasKey, t } from '../../shared/i18n';
import type { RunHistoryData, RunHistoryEvent } from '../../types/oversight';
import { historyKey } from './reviewQueue';
import '../screens/ReviewQueue.css';

const KIND_TONE: Record<RunHistoryEvent['kind'], BadgeTone> = {
    row: 'neutral',
    flag: 'danger',
    note: 'primary',
    decision: 'warning',
    dispute: 'warning',
    batch: 'danger',
};

function line(e: RunHistoryEvent): string {
    const key = historyKey(e);
    const vars = {
        who: e.citizenid ?? '-',
        by: e.actor ?? '-',
        state: hasKey(`sup.state.${e.action}`) ? t(`sup.state.${e.action}`) : e.action,
        flag: e.new && hasKey(`flag.${e.new}`) ? t(`flag.${e.new}`) : (e.new ?? ''),
        kind: hasKey(`ui.admin_officers.batch.${e.action}`) ? t(`ui.admin_officers.batch.${e.action}`) : e.action,
        action: e.action,
    };
    return hasKey(key) ? t(key, vars) : t('sup.history.action.other', vars);
}

export function RunHistoryList({ events }: { events: RunHistoryEvent[] | null | undefined }) {
    const list = asArray(events);
    if (!list.length) return <p className="oversight-rq-soft">{t('sup.history.none')}</p>;
    return (
        <ol className="oversight-rq-history">
            {list.map((e, i) => (
                <li key={`${e.at}-${e.kind}-${i}`} className="oversight-rq-history__item">
                    <span className="oversight-rq-history__when cp-num">{formatDateTime(e.at)}</span>
                    <Badge size="sm" tone={KIND_TONE[e.kind] ?? 'neutral'} variant="outline">
                        {t(`sup.history.kind.${e.kind}`)}
                    </Badge>
                    <span className="oversight-rq-history__text">
                        {line(e)}
                        {e.reason || e.detail ? (
                            <span className="oversight-rq-soft"> · {e.reason || e.detail}</span>
                        ) : null}
                    </span>
                </li>
            ))}
        </ol>
    );
}

export function RunHistoryDialog({ runUuid, onClose }: { runUuid: string | null; onClose: () => void }) {
    const { data, loading, error, refetch } = useRequest<RunHistoryData>(
        'review:getRunHistory',
        { runUuid: runUuid ?? '' },
        { skip: !runUuid },
    );
    return (
        <Dialog
            open={!!runUuid}
            onClose={onClose}
            size="lg"
            title={t('sup.history.title')}
            description={runUuid ? t('sup.history.run', { id: runUuid }) : undefined}
            footer={
                <Button variant="ghost" onClick={onClose}>
                    {t('common.close')}
                </Button>
            }
        >
            {loading && !data ? (
                <LoadingBlock />
            ) : error && !data ? (
                <ErrorState error={error} onRetry={() => void refetch()} />
            ) : (
                <RunHistoryList events={data?.events} />
            )}
        </Dialog>
    );
}
