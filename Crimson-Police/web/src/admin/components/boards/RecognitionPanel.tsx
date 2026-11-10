// Leaderboards → Recognition: what officers' Home shows, the last closed weeks (Recount, Post again) and the notices
// (shared/NoticesCard, kind staff: post, end any running notice, the history).

import { useState } from 'react';
import {
    Badge,
    Button,
    Card,
    Checkbox,
    ConfirmDialog,
    EmptyState,
    ErrorState,
    LoadingBlock,
    Row,
} from '../../../shared/components';
import { formatNumber } from '../../../shared/format';
import { useRequest } from '../../../shared/hooks';
import { request } from '../../../shared/nui';
import { t } from '../../../shared/i18n';
import type { RecognitionData, WeekRecognition } from '../../../types/admin_officers';
import { NoticesCard } from '../../../shared/NoticesCard';
import { useAdminAction } from '../kit';
import '../officers/OfficerTools.css';

export function RecognitionPanel() {
    const { data, loading, error, refetch } = useRequest<RecognitionData>('admin:getRecognition', {});
    const { run, busy } = useAdminAction();
    const [recount, setRecount] = useState<{ week: WeekRecognition; post: boolean } | null>(null);
    const [repost, setRepost] = useState<WeekRecognition | null>(null);
    const openRecount = async (week: WeekRecognition) => {
        const res = await request<WeekRecognition>('admin:previewRecount', { weekKey: week.weekKey });
        if (res.ok && res.data) setRecount({ week: res.data, post: true });
    };
    const doRecount = async (reason: string, typed: string) => {
        if (!recount) return;
        const res = await run(
            'server:admin:recountWeek',
            {
                weekKey: recount.week.weekKey,
                post: recount.post,
                reason,
                confirm: typed,
                previewToken: recount.week.previewToken,
            },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        setRecount(null);
        if (res.ok) void refetch();
    };
    const doRepost = async () => {
        if (!repost) return;
        await run(
            'server:admin:repostWeek',
            { weekKey: repost.weekKey },
            { requestId: false, success: 'ui.admin_officers.done' },
        );
        setRepost(null);
    };
    if (!data && loading) return <LoadingBlock />;
    if (!data && error) return <ErrorState error={error} onRetry={() => void refetch()} />;
    if (!data) return null;

    return (
        <div className="admin-otools">
            <Card
                title={t('ui.admin_officers.recognition.home')}
                icon="home"
                subtitle={t('ui.admin_officers.recognition.home_hint')}
                padding="md"
            >
                <Row gap={2} wrap>
                    <Badge tone={data.announceWeekly ? 'success' : 'grey'}>
                        {t(
                            data.announceWeekly
                                ? 'ui.admin_officers.recognition.weekly_on'
                                : 'ui.admin_officers.recognition.weekly_off',
                        )}
                    </Badge>
                    <Badge tone={data.announceMonthly ? 'success' : 'grey'}>
                        {t(
                            data.announceMonthly
                                ? 'ui.admin_officers.recognition.monthly_on'
                                : 'ui.admin_officers.recognition.monthly_off',
                        )}
                    </Badge>
                </Row>
                {data.home.length ? (
                    <ul className="admin-otools__badges">
                        {data.home.map((a, i) => (
                            <li key={i}>
                                <span>{a.text}</span>
                                <Badge size="sm" variant="outline">
                                    {t(
                                        `ui.admin_officers.recognition.kind.${a.kind === 'staff_notice' ? 'notice' : a.kind === 'monthly_top3' ? 'monthly' : 'weekly'}`,
                                    )}
                                </Badge>
                            </li>
                        ))}
                    </ul>
                ) : (
                    <EmptyState compact icon="home" title={t('ui.admin_officers.recognition.home_empty')} />
                )}
            </Card>

            <NoticesCard kind="staff" />

            <Card
                title={t('ui.admin_officers.recognition.weeks')}
                icon="trophy"
                subtitle={t('ui.admin_officers.recognition.weeks_hint')}
                padding="md"
            >
                <ul className="admin-otools__badges">
                    {data.weeks.map(w => (
                        <li key={w.weekKey}>
                            <span>
                                {t('ui.admin_officers.recognition.week_of', { week: w.weekKey })}:{' '}
                                {w.top[0] ? `${w.top[0].name} (${formatNumber(w.top[0].points)})` : t('common.none')}
                            </span>
                            <span className="admin-otools__soft">
                                {t('ui.admin_officers.recognition.holder', {
                                    who: w.holders.map(h => h.name).join(', ') || t('common.none'),
                                })}
                            </span>
                            {w.changed ? (
                                <Badge size="sm" tone="warning">
                                    {t('ui.admin_officers.recognition.changed')}
                                </Badge>
                            ) : null}
                            <Button size="sm" variant="secondary" disabled={busy} onClick={() => void openRecount(w)}>
                                {t('ui.admin_officers.recognition.recount')}
                            </Button>
                            <Button
                                size="sm"
                                variant="ghost"
                                disabled={busy || !w.top.length}
                                onClick={() => setRepost(w)}
                            >
                                {t('ui.admin_officers.recognition.repost')}
                            </Button>
                        </li>
                    ))}
                </ul>
            </Card>

            <ConfirmDialog
                open={!!recount}
                tone="danger"
                title={t('ui.admin_officers.recognition.recount')}
                message={
                    recount
                        ? t('ui.admin_officers.recognition.recount_message', {
                              old: recount.week.holders.map(h => h.name).join(', ') || t('common.none'),
                              new: recount.week.top[0]?.name ?? t('common.none'),
                          })
                        : null
                }
                effect={
                    recount ? (
                        <Checkbox
                            checked={recount.post}
                            onChange={v => setRecount({ ...recount, post: v })}
                            label={t('ui.admin_officers.recognition.post_correction')}
                        />
                    ) : null
                }
                typedWord="RECOUNT"
                reason={{ required: true, maxLength: 255 }}
                onConfirm={doRecount}
                onCancel={() => setRecount(null)}
                busy={busy}
            />
            <ConfirmDialog
                open={!!repost}
                title={t('ui.admin_officers.recognition.repost')}
                message={repost ? t('ui.admin_officers.recognition.repost_message', { week: repost.weekKey }) : null}
                onConfirm={doRepost}
                onCancel={() => setRepost(null)}
                busy={busy}
            />
        </div>
    );
}
