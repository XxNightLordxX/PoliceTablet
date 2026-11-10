// Supervisor UI · Department → Review: the one Review queue (flagged runs and disputes of the supervisor's

// Supervisor UI · Department → Review: the one Review queue (flagged runs and disputes of the supervisor's
// department in one list with a Type column, supervisor/components/ReviewQueuePanel.tsx) and, with reviewProfiles,
// Profiles (pictures, bios and reports). Runs they took part in never appear; runs of their other characters may, but
// every action on them is refused (err.own_run).

import { useState } from 'react';
import { IconButton, Screen, Tabs } from '../../shared/components';
import { t } from '../../shared/i18n';
import { useCan } from '../../shared/session';
import type { ReviewTab } from '../../types/oversight';
import { ProfilesReview } from '../components/ProfilesReview';
import { ReviewQueuePanel } from '../components/ReviewQueuePanel';
import './ReviewQueue.css';

export default function SupReviewQueue() {
    const can = useCan();
    const canQueue = can('reviewFlagged') || can('handleDisputes');
    const canProfiles = can('reviewProfiles');
    const [tab, setTab] = useState<ReviewTab>(canQueue ? 'queue' : 'profiles');
    // a new key remounts the queue, so Refresh asks again at once
    const [round, setRound] = useState(0);
    const tabs = [
        ...(canQueue ? [{ key: 'queue' as const, label: t('sup.review.tab.queue'), icon: 'flag' as const }] : []),
        ...(canProfiles ? [{ key: 'profiles' as const, label: t('profile.review.tab'), icon: 'user' as const }] : []),
    ];
    const current: ReviewTab = tabs.some(x => x.key === tab) ? tab : (tabs[0]?.key ?? 'queue');
    return (
        <Screen
            head="sup_review"
            subtitle={t('sup.review.subtitle')}
            actions={
                current === 'queue' ? (
                    <IconButton
                        icon="refresh"
                        label={t('sup.refresh')}
                        variant="secondary"
                        onClick={() => setRound(n => n + 1)}
                    />
                ) : null
            }
            className="oversight-screen"
        >
            {tabs.length > 1 ? (
                <Tabs
                    items={tabs}
                    value={current}
                    onChange={k => setTab(k as ReviewTab)}
                    aria-label={t('ui.screen.sup_review')}
                />
            ) : null}
            {current === 'profiles' ? <ProfilesReview /> : <ReviewQueuePanel key={round} />}
        </Screen>
    );
}
