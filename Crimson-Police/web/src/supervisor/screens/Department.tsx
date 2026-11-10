// Supervisor UI · Department (screen key 'sup_department'): Officers (supervisor/screens/DeptReport), Controls

// Supervisor UI · Department (screen key 'sup_department'): Officers (supervisor/screens/DeptReport), Controls
// (supervisor/screens/MissionControls, each control's admin limits and today's use inline), Review
// (supervisor/screens/ReviewQueue), Calls & notices (supervisor/components/MissionCallsPanel and DeptNoticesCard) and
// Training (supervisor/components/FieldTrainingPanel), each the old screen or panel itself. params.deptTab picks the
// tab; layouts/supDepartment.ts maps the old keys onto it and keeps each tab's permission.

import { useEffect, useState } from 'react';
import { Screen, Tabs } from '../../shared/components';
import { t } from '../../shared/i18n';
import { useNavigation } from '../../shared/navigation';
import { useCan, useSession } from '../../shared/session';
import { deptTabOf, deptTabsFor, type DeptTab } from '../../layouts/supDepartment';
import { DeptNoticesCard } from '../components/DeptNoticesCard';
import { FieldTrainingPanel } from '../components/FieldTrainingPanel';
import MissionCallsPanel from '../components/MissionCallsPanel';
import DeptReport from './DeptReport';
import MissionControls from './MissionControls';
import ReviewQueue from './ReviewQueue';

function CallsAndNotices() {
    const session = useSession();
    const can = useCan();
    return (
        <Screen title={t('sup.dept.tab.calls')} subtitle={t('sup.dept.calls_help')}>
            {can('missionCalls') ? <MissionCallsPanel scope={session.officer ? 'sup' : 'admin'} /> : null}
            <DeptNoticesCard />
        </Screen>
    );
}

function Training() {
    return (
        <Screen title={t('sup.dept.tab.training')} className="boards-report">
            <FieldTrainingPanel showOff />
        </Screen>
    );
}

function TabBody({ tab }: { tab: DeptTab }) {
    switch (tab) {
        case 'controls':
            return <MissionControls key="controls" />;
        case 'review':
            return <ReviewQueue key="review" />;
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
    const { params } = useNavigation();
    const tabs = deptTabsFor(session);
    const [tab, setTab] = useState<DeptTab>(deptTabOf(params, session));
    // a link opened while the screen shows (an old key, a notification) picks its tab
    // eslint-disable-next-line react-hooks/exhaustive-deps
    useEffect(() => setTab(deptTabOf(params, session)), [params]);
    const shown = tabs.includes(tab) ? tab : deptTabOf(null, session);
    return (
        <>
            <Tabs<DeptTab>
                className="sup-dept__tabs"
                aria-label={t('sup.dept.tabs')}
                value={shown}
                onChange={setTab}
                items={tabs.map(k => ({ key: k, label: t(`sup.dept.tab.${k}`) }))}
            />
            <TabBody tab={shown} />
        </>
    );
}
