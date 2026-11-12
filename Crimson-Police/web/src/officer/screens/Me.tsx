// Officer UI · Me (screen key 'me'): Profile & History (officer/screens/Profile), Leaderboard
// (officer/screens/Leaderboard) and Department Challenge (officer/screens/Challenge) as tabs of one screen, each the old
// screen itself. params.meTab picks the tab (layouts/officerMe.ts); params.citizenid opens an officer's public profile.

import { Tabs } from '../../shared/components';
import { t } from '../../shared/i18n';
import { useNavigation } from '../../shared/navigation';
import { ME_TABS, meLink, meTabOf, type MeTab } from '../../layouts/officerMe';
import Challenge from './Challenge';
import Leaderboard from './Leaderboard';
import Profile from './Profile';

function TabBody({ tab }: { tab: MeTab }) {
    switch (tab) {
        case 'leaderboard':
            return <Leaderboard key="leaderboard" />;
        case 'challenge':
            return <Challenge key="challenge" />;
        default:
            return <Profile key="profile" />;
    }
}

export default function Me() {
    const { params, navigate } = useNavigation();
    // the tab is the link's (a leaderboard row, a contributor, Back); picking a tab opens it fresh (the own profile)
    const tab = meTabOf(params);
    return (
        <>
            <Tabs<MeTab>
                className="cp-me__tabs"
                aria-label={t('officer.me.tabs')}
                value={tab}
                onChange={k => navigate('me', meLink(k))}
                items={ME_TABS.map(k => ({ key: k, label: t(`officer.me.tab.${k}`) }))}
            />
            <TabBody tab={tab} />
        </>
    );
}
