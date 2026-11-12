// Supervisor UI · Department (screen key 'sup_department'): Officers (supervisor/screens/DeptReport), Controls

// Supervisor UI · Department (screen key 'sup_department'): Officers (supervisor/screens/DeptReport), Controls
// (supervisor/screens/MissionControls, each control's admin limits and today's use inline), Review
// (supervisor/screens/ReviewQueue), Restrictions (admin/components/RestrictionsPanel, his department), Calls & notices (supervisor/components/MissionCallsPanel and shared/NoticesCard) and
// Training (supervisor/components/FieldTrainingPanel), each the old screen or panel itself. params.deptTab picks the
// tab; layouts/supDepartment.ts keeps each tab's permission. Above the tabs, today at a glance (UI4, sup:getToday and
// the sidebar's Review Queue count): officers on duty, runs going, waiting for review and the supervisor's controls
// used today, each a click away from the tab or screen where he acts on it.

import { Icon, Screen, TabbedScreen, type IconName } from '../../shared/components';
import { cx } from '../../shared/cx';
import { usePush, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigation } from '../../shared/navigation';
import { useCan, useSession } from '../../shared/session';
import { useNavCounts } from '../../layouts/navBadges';
import { screensFor } from '../../layouts/screens';
import { deptTabOf, deptTabsFor, todayTiles, type DeptTab, type TodayKey } from '../../layouts/supDepartment';
import type { SupToday } from '../../types/oversight';
import './Department.css';
import { NoticesCard } from '../../shared/NoticesCard';
import { FieldTrainingPanel } from '../components/FieldTrainingPanel';
import MissionCallsPanel from '../components/MissionCallsPanel';
import { useTodayChanged } from '../components/todayRefresh';
import DeptReport from './DeptReport';
import MissionControls from './MissionControls';
import ReviewQueue from './ReviewQueue';
import { RestrictionsPanel } from '../../admin/components/RestrictionsPanel';

function CallsAndNotices() {
    const session = useSession();
    const can = useCan();
    return (
        <Screen head="sup_calls">
            {can('missionCalls') ? <MissionCallsPanel scope={session.officer ? 'sup' : 'admin'} /> : null}
            <NoticesCard kind="department" />
        </Screen>
    );
}

function Training() {
    return (
        <Screen head="sup_training" className="boards-report">
            <FieldTrainingPanel showOff />
        </Screen>
    );
}

const TODAY_ICON: Record<TodayKey, IconName> = {
    onDuty: 'users',
    running: 'activity',
    review: 'inbox',
    controls: 'sliders',
};

// Today at a glance: one tile per number; a click opens its tab (or Live Missions). Asked every 30 s, again on a
// Mission controls push and the moment a side panel action is taken (todayChanged).
function Today({ tabs, onTab }: { tabs: DeptTab[]; onTab: (tab: DeptTab) => void }) {
    const session = useSession();
    const { navigate } = useNavigation();
    const shown = tabs.includes('officers');
    const { data, refetch } = useRequest<SupToday>('sup:getToday', {}, { skip: !shown, pollMs: 30000 });
    usePush(shown ? 'missionControls' : null, () => void refetch());
    useTodayChanged(() => {
        if (shown) void refetch();
    });
    const counts = useNavCounts(shown && tabs.includes('review'));
    const screens = screensFor('supervisor', session).map(s => s.key);
    const tiles = todayTiles(data, counts.review, tabs, screens);
    if (tiles.length === 0) return null;
    return (
        <section className="sup-today" aria-label={t('sup.today.title')} data-tour="sup-today">
            {tiles.map(tile => (
                <button
                    key={tile.key}
                    type="button"
                    className={cx('sup-today__tile', tile.warn && 'is-warn')}
                    disabled={!tile.open}
                    onClick={() => {
                        if (!tile.open) return;
                        if (tile.open.deptTab) onTab(tile.open.deptTab);
                        else navigate(tile.open.screen);
                    }}
                >
                    <span className="sup-today__label">
                        <Icon name={TODAY_ICON[tile.key]} size={14} />
                        {t(`sup.today.${tile.key}`)}
                    </span>
                    <span className="sup-today__value cp-num">{tile.value}</span>
                </button>
            ))}
        </section>
    );
}

function TabBody({ tab }: { tab: DeptTab }) {
    switch (tab) {
        case 'controls':
            return <MissionControls key="controls" />;
        case 'review':
            return <ReviewQueue key="review" />;
        case 'restrictions':
            return <RestrictionsPanel key="restrictions" scope="sup" />;
        case 'calls':
            return <CallsAndNotices key="calls" />;
        case 'training':
            return <Training key="training" />;
        default:
            return <DeptReport key="officers" />;
    }
}

export default function Department() {
    const session = useSession();
    const tabs = deptTabsFor(session);
    return (
        <TabbedScreen<DeptTab>
            className="sup-dept__tabs"
            aria-label={t('sup.dept.tabs')}
            tabOf={params => deptTabOf(params, session)}
            items={tabs.map(k => ({ key: k, label: t(`sup.dept.tab.${k}`) }))}
            above={setTab => <Today tabs={tabs} onTab={setTab} />}
        >
            {tab => <TabBody tab={tab} />}
        </TabbedScreen>
    );
}
