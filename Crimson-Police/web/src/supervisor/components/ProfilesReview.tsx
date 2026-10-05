// Review Queue → Profiles: pending pictures and bios of the department and the profile reports. Approve, reject,
// clear and dismiss each need a reason and are audited. Callback sup:getProfileQueue.

import { useState } from 'react';
import {
    Avatar,
    Badge,
    Button,
    ConfirmDialog,
    EmptyState,
    ErrorState,
    Icon,
    LoadingBlock,
    Row,
} from '../../shared/components';
import { fmtDateTime } from '../../shared/format';
import { useAction, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { asList } from '../../types/boards';
import type { ProfileQueueItem } from '../../types/profile';
import './ProfilesReview.css';

type Decision =
    { item: ProfileQueueItem; action: 'approve' | 'reject' } | { item: ProfileQueueItem; action: 'clear' | 'dismiss' };

export interface ProfilesReviewProps {
    // 'admin' uses the admin:* actions (every department)
    scope?: 'sup' | 'admin';
}

function itemKey(i: ProfileQueueItem): string {
    return `${i.kind}-${i.id ?? i.citizenid}`;
}

export function ProfilesReview({ scope = 'sup' }: ProfilesReviewProps) {
    const { data, loading, error, refetch } = useRequest<ProfileQueueItem[]>(
        'sup:getProfileQueue',
        {},
        {
            pollMs: 60000,
            pushTopic: 'profile',
        },
    );
    const { run, busy } = useAction();
    const [pending, setPending] = useState<Decision | null>(null);
    const items = asList(data ?? undefined);

    async function confirm(reason: string) {
        if (!pending) return;
        const { item, action } = pending;
        let res;
        if (item.kind === 'report') {
            res = await run(
                scope === 'admin' ? 'server:admin:handleReport' : 'server:sup:handleReport',
                { id: item.id, decision: action, reason },
                { success: action === 'clear' ? 'profile.review.done_clear' : 'profile.review.done_dismiss' },
            );
        } else {
            res = await run(
                scope === 'admin' ? 'server:admin:reviewAvatar' : 'server:sup:reviewAvatar',
                { citizenid: item.citizenid, decision: action, reason, what: item.kind },
                { success: action === 'approve' ? 'profile.review.done_approve' : 'profile.review.done_reject' },
            );
        }
        setPending(null);
        if (res.ok) await refetch();
    }

    if (!data && loading) return <LoadingBlock />;
    if (!data && error) return <ErrorState error={error} onRetry={() => void refetch()} />;
    if (items.length === 0) {
        return (
            <EmptyState icon="shieldCheck" title={t('profile.review.empty')} text={t('profile.review.empty_text')} />
        );
    }

    return (
        <div className="profile-review">
            {items.map(item => (
                <div key={itemKey(item)} className="profile-review__item">
                    <div className="profile-review__who">
                        <span className="profile-review__name" title={item.name}>
                            {item.name}
                        </span>
                        <span className="profile-review__sub">
                            <Badge size="sm" variant="outline">
                                {item.departmentShort}
                            </Badge>
                            <span>{item.callsign || t('common.no_callsign')}</span>
                            <span>{fmtDateTime(item.submittedAt)}</span>
                        </span>
                    </div>
                    <div className="profile-review__what">
                        <Badge tone={item.kind === 'report' ? 'warning' : 'accent'} size="sm">
                            {t(`profile.review.kind.${item.kind}`)}
                        </Badge>
                        {item.kind === 'report' && item.reason ? (
                            <Badge tone="neutral" size="sm">
                                {t(`profile.report.reason.${item.reason}`)}
                            </Badge>
                        ) : null}
                    </div>
                    <div className="profile-review__content">
                        {item.url ? (
                            <Avatar
                                avatar={{ kind: 'url', value: item.url, initials: '?', frame: 'grey' }}
                                size={56}
                                label={t('profile.review.picture')}
                            />
                        ) : null}
                        {item.url ? (
                            <span className="profile-review__url" title={item.url}>
                                <Icon name="globe" size={13} /> {item.url}
                            </span>
                        ) : null}
                        {item.text ? <p className="profile-review__text">{item.text}</p> : null}
                        {item.kind === 'bio' && item.current ? (
                            <p className="profile-review__old">
                                {t('profile.review.current_bio', { bio: item.current })}
                            </p>
                        ) : null}
                        {item.note ? <p className="profile-review__note">“{item.note}”</p> : null}
                        {item.kind === 'report' && item.reporter ? (
                            <p className="profile-review__old">
                                {t('ui.admin_officers.review.reporter', {
                                    name: item.reporter.callsign
                                        ? `${item.reporter.callsign} ${item.reporter.name}`
                                        : item.reporter.name,
                                    n: item.reporter.recent,
                                })}
                            </p>
                        ) : null}
                    </div>
                    <Row gap={2} className="profile-review__actions">
                        {item.kind === 'report' ? (
                            <>
                                <Button
                                    size="sm"
                                    variant="danger"
                                    onClick={() => setPending({ item, action: 'clear' })}
                                >
                                    {t('profile.review.clear')}
                                </Button>
                                <Button
                                    size="sm"
                                    variant="secondary"
                                    onClick={() => setPending({ item, action: 'dismiss' })}
                                >
                                    {t('profile.review.dismiss')}
                                </Button>
                            </>
                        ) : (
                            <>
                                <Button
                                    size="sm"
                                    variant="primary"
                                    icon="check"
                                    onClick={() => setPending({ item, action: 'approve' })}
                                >
                                    {t('profile.review.approve')}
                                </Button>
                                <Button
                                    size="sm"
                                    variant="danger"
                                    icon="x"
                                    onClick={() => setPending({ item, action: 'reject' })}
                                >
                                    {t('profile.review.reject')}
                                </Button>
                            </>
                        )}
                    </Row>
                </div>
            ))}
            <ConfirmDialog
                open={!!pending}
                title={pending ? t(`profile.review.confirm_${pending.action}`) : ''}
                message={pending ? t('profile.review.confirm_text', { name: pending.item.name }) : ''}
                tone={pending && (pending.action === 'reject' || pending.action === 'clear') ? 'danger' : 'primary'}
                reason={{ label: t('common.reason'), required: true, maxLength: 255 }}
                onConfirm={confirm}
                onCancel={() => setPending(null)}
                busy={busy}
            />
        </div>
    );
}

export default ProfilesReview;
