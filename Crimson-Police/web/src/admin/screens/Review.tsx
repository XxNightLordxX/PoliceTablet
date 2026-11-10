// Admin UI · Review (screen key 'admin_review'): everything an admin checks and decides, as three tabs. Queue (the

// Admin UI · Review (screen key 'admin_review'): everything an admin checks and decides, as three tabs. Queue (the
// one Review queue of every department: flagged runs and disputes in one list with a Type column, the admin's own
// runs left out; supervisor/components/ReviewQueuePanel.tsx with all, server:review:decide), Profiles (every pending
// picture, bio and report, and the banned words) and Corrections (bulk voids, retirements, record moves and season
// reopens, with Undo). A link to a tab is navigate('admin_review', { tab, show? }) (show = 'flag' | 'dispute' picks
// the queue's filter). The Activity log (Audit) sits beside it in the Review group.

import { useEffect, useState } from 'react';
import { Screen, TabbedScreen } from '../../shared/components';
import { t } from '../../shared/i18n';
import { useNavigation, type ScreenParams } from '../../shared/navigation';
import { ReviewQueuePanel } from '../../supervisor/components/ReviewQueuePanel';
import { showOf, type ReviewShow } from '../../supervisor/components/reviewQueue';
import { CorrectionsTab, ReviewTab } from '../components/officers/OfficerLists';
import './Leaderboards.css';
import '../../supervisor/screens/ReviewQueue.css';

export type AdminReviewTab = 'queue' | 'profiles' | 'corrections';
export const REVIEW_TABS: AdminReviewTab[] = ['queue', 'profiles', 'corrections'];
const TAB_ICONS = { queue: 'flag', profiles: 'eye', corrections: 'undo' } as const;

// The tab the screen shows for its params (the queue unless another tab is asked for).
export function reviewTabOf(params: ScreenParams | null | undefined): AdminReviewTab {
    const asked = params?.tab;
    return typeof asked === 'string' && (REVIEW_TABS as string[]).includes(asked) ? (asked as AdminReviewTab) : 'queue';
}

export default function AdminReview() {
    const { params, navigate } = useNavigation();
    const [show, setShow] = useState<ReviewShow>(showOf(params?.show));
    // a link opened while the screen shows (Home's tiles, the search) picks the queue's filter
    useEffect(() => setShow(showOf(params?.show)), [params]);
    return (
        <Screen head="admin_review" className="oversight-screen">
            <TabbedScreen<AdminReviewTab>
                items={REVIEW_TABS.map(k => ({ key: k, label: t(`admin.review.tab.${k}`), icon: TAB_ICONS[k] }))}
                tabOf={reviewTabOf}
                aria-label={t('ui.nav.plain.admin_review')}
            >
                {tab => (
                    <>
                        {tab === 'queue' ? (
                            <ReviewQueuePanel
                                all
                                show={show}
                                onOpenOfficer={cid => navigate('admin_officers', { citizenid: cid })}
                            />
                        ) : null}
                        {tab === 'profiles' ? <ReviewTab /> : null}
                        {tab === 'corrections' ? <CorrectionsTab /> : null}
                    </>
                )}
            </TabbedScreen>
        </Screen>
    );
}
