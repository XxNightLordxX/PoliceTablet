// An officer's commendations, newest first, plus the read-only SC-Dispatch MDT commendations (tagged MDT). Staff
// views pass onRevoke to offer Revoke on the ones still active.

import { Badge, Button, Card, EmptyState, Icon } from '../../shared/components';
import { cx } from '../../shared/cx';
import { fmtDate } from '../../shared/format';
import { hasKey, t } from '../../shared/i18n';
import { asList } from '../../types/boards';
import type { Commendation } from '../../types/profile';
import './ProfileCards.css';

export function commendationKindLabel(kind: string): string {
    return hasKey(`profile.commend.kind.${kind}`) ? t(`profile.commend.kind.${kind}`) : kind;
}

export interface CommendationsCardProps {
    commendations: Commendation[] | null | undefined;
    mdt?: { title: string; by: string; at: number }[] | null;
    onRevoke?: (c: Commendation) => void;
    // which active ones offer Revoke (default: every one)
    canRevoke?: (c: Commendation) => boolean;
    // a Commend button in the header (supervisors and admins)
    onCommend?: () => void;
}

export function CommendationsCard({ commendations, mdt, onRevoke, canRevoke, onCommend }: CommendationsCardProps) {
    const list = asList(commendations ?? undefined);
    const mdtList = asList(mdt ?? undefined);
    return (
        <Card
            title={t('profile.commend.title')}
            icon="medal"
            padding="sm"
            className="profile-commend"
            actions={
                onCommend ? (
                    <Button size="sm" variant="secondary" icon="plus" onClick={onCommend}>
                        {t('profile.commend.give')}
                    </Button>
                ) : undefined
            }
        >
            {list.length === 0 && mdtList.length === 0 ? (
                <EmptyState compact icon="medal" title={t('profile.commend.none')} />
            ) : (
                <ul className="profile-commend__list">
                    {list.map(c => (
                        <li key={c.id} className={cx('profile-commend__item', c.revoked && 'is-revoked')}>
                            <span className="profile-commend__icon" aria-hidden>
                                <Icon name="medal" size={16} />
                            </span>
                            <span className="profile-commend__text">
                                <span className="profile-commend__head">
                                    <strong>{commendationKindLabel(c.kind)}</strong>
                                    {c.revoked ? (
                                        <Badge tone="danger" size="sm">
                                            {t('profile.commend.revoked')}
                                        </Badge>
                                    ) : null}
                                </span>
                                <span className="profile-commend__citation">{c.citation}</span>
                                <span className="profile-commend__by">
                                    {t('profile.commend.by', {
                                        name: c.byRank ? `${c.byRank} ${c.by}` : c.by,
                                        date: fmtDate(c.at),
                                    })}
                                    {c.revoked && c.revokeReason ? ` · ${c.revokeReason}` : ''}
                                </span>
                            </span>
                            {onRevoke && !c.revoked && (!canRevoke || canRevoke(c)) ? (
                                <Button size="sm" variant="ghost" icon="xCircle" onClick={() => onRevoke(c)}>
                                    {t('profile.commend.revoke')}
                                </Button>
                            ) : null}
                        </li>
                    ))}
                    {mdtList.map((m, i) => (
                        <li key={`mdt-${i}`} className="profile-commend__item is-mdt">
                            <span className="profile-commend__icon" aria-hidden>
                                <Icon name="fileText" size={16} />
                            </span>
                            <span className="profile-commend__text">
                                <span className="profile-commend__head">
                                    <strong>{m.title}</strong>
                                    <Badge tone="neutral" size="sm" variant="outline">
                                        {t('profile.commend.mdt')}
                                    </Badge>
                                </span>
                                <span className="profile-commend__by">
                                    {t('profile.commend.by', { name: m.by, date: fmtDate(m.at) })}
                                </span>
                            </span>
                        </li>
                    ))}
                </ul>
            )}
        </Card>
    );
}

export default CommendationsCard;
