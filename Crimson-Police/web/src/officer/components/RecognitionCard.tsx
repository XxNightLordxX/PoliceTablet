// Profile · Recognition (Config.Recognition): everything an officer is recognised with, in one section with a tab
// per kind: his badges, his commendations (with the read-only SC-Dispatch MDT ones) and, on his own profile while
// field training is on, his training as a rookie and his rookies as a trainer (Sign off).

import { useState } from 'react';
import { Card, EmptyState, Icon, Tabs, type IconName, type TabItem } from '../../shared/components';
import { cx } from '../../shared/cx';
import { formatDateTime } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { asList, type ProfileData } from '../../types/boards';
import type { FtoMine } from '../../types/fieldTraining';
import type { Commendation } from '../../types/profile';
import { CommendationsCard } from './CommendationsCard';
import { FieldTrainingCard } from './FieldTrainingCard';
import './ProfileCards.css';

const BADGE_ICON: Record<string, IconName> = {
    week: 'star',
    champion: 'trophy',
    top10: 'podium',
    achievement: 'shieldCheck',
};

type RecognitionTab = 'badges' | 'commendations' | 'training';

export interface RecognitionCardProps {
    badges: ProfileData['badges'] | null | undefined;
    commendations: Commendation[] | null | undefined;
    mdt?: { title: string; by: string; at: number }[] | null;
    // the officer's own profile: the empty texts speak to him and the Field training tab can show
    own: boolean;
}

export function RecognitionCard({ badges, commendations, mdt, own }: RecognitionCardProps) {
    const [tab, setTab] = useState<RecognitionTab>('badges');
    const fto = useRequest<FtoMine | false>('fto:getMine', {}, { skip: !own });
    const list = asList(badges ?? undefined);
    const commendCount = asList(commendations ?? undefined).length + asList(mdt ?? undefined).length;
    const training = own && fto.data ? fto.data : null;
    const items: TabItem<RecognitionTab>[] = [
        { key: 'badges', label: t('profile.badges'), icon: 'medal', badge: list.length || undefined },
        { key: 'commendations', label: t('profile.commend.title'), icon: 'star', badge: commendCount || undefined },
    ];
    if (training) items.push({ key: 'training', label: t('fto.title'), icon: 'idCard' });
    const current: RecognitionTab = tab === 'training' && !training ? 'badges' : tab;

    return (
        <Card title={t('profile.recognition')} icon="medal" padding="sm" className="profile-recognition">
            <Tabs items={items} value={current} onChange={setTab} aria-label={t('profile.recognition')} />
            {current === 'badges' ? (
                list.length ? (
                    <div className="boards-badges">
                        {list.map(b => (
                            <div
                                key={b.id}
                                className={cx('boards-badge', `is-${b.kind ?? 'achievement'}`)}
                                title={
                                    b.earnedAt ? t('profile.earned', { when: formatDateTime(b.earnedAt) }) : undefined
                                }
                            >
                                <span className="boards-badge__icon">
                                    <Icon name={BADGE_ICON[b.kind ?? 'achievement'] ?? 'shieldCheck'} size={16} />
                                </span>
                                <span className="boards-badge__text">
                                    <span className="boards-badge__label">{b.label}</span>
                                    {b.earnedAt ? (
                                        <span className="boards-badge__when">{formatDateTime(b.earnedAt)}</span>
                                    ) : null}
                                </span>
                            </div>
                        ))}
                    </div>
                ) : (
                    <EmptyState
                        compact
                        icon="medal"
                        title={t('profile.no_badges')}
                        text={own ? t('profile.no_badges_text') : undefined}
                    />
                )
            ) : null}
            {current === 'commendations' ? <CommendationsCard bare commendations={commendations} mdt={mdt} /> : null}
            {current === 'training' && training ? (
                <>
                    <p className="profile-commend__by">{t('fto.subtitle')}</p>
                    <FieldTrainingCard bare mine={training} onChanged={() => void fto.refetch()} />
                </>
            ) : null}
        </Card>
    );
}

export default RecognitionCard;
