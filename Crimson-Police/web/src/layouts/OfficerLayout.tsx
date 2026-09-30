// Officer UI: tablet frame in the department theme and the officer's look, header, the 8-screen sidebar with its
// badges, watermark, the pinned current-run bar, the unit ready check and the Supervisor switch (session.roles).

import { ReadyCheckBanner } from '../officer/components/ReadyCheckBanner';
import { Button, Watermark } from '../shared/components';
import { setMoneyFormat } from '../shared/format';
import { usePush } from '../shared/hooks';
import { t } from '../shared/i18n';
import { useNavigation, type ScreenKey } from '../shared/navigation';
import { useSession, useTablet } from '../shared/session';
import { Header } from './Header';
import { navBadge, useNavCounts } from './navBadges';
import { RunBar } from './RunBar';
import { ScreenHost } from './ScreenHost';
import { screensFor } from './screens';
import { Sidebar } from './Sidebar';
import { TABLET_H, TabletFrame } from './TabletFrame';

export function OfficerLayout() {
    const session = useSession();
    const { close, switchUi, switching, refreshSession } = useTablet();
    const { screen, navigate } = useNavigation();
    const screens = screensFor('officer', session);
    const counts = useNavCounts();
    setMoneyFormat(session.config.format);
    // the own profile changed (look, picture approved): the session carries the new look
    usePush('profile', () => void refreshSession());

    return (
        <TabletFrame theme={session.theme} prefs={session.prefs} profile={session.config.profile}>
            <Header session={session} ui="officer" onClose={close} />
            <div className="cp-tablet__body">
                <Sidebar
                    heading={t('ui.nav.officer')}
                    items={screens.map(s => ({
                        key: s.key,
                        label: t(s.titleKey),
                        icon: s.icon,
                        ...navBadge(s.key, counts),
                    }))}
                    active={screen}
                    onSelect={k => navigate(k as ScreenKey)}
                    footer={
                        session.roles.supervisor ? (
                            <Button
                                variant="secondary"
                                block
                                icon="swap"
                                loading={switching}
                                onClick={() => void switchUi('supervisor')}
                            >
                                {t('ui.switch.supervisor')}
                            </Button>
                        ) : null
                    }
                />
                <main className="cp-main">
                    <Watermark logo={session.logo} department={session.officer?.department} tabletHeight={TABLET_H} />
                    <RunBar />
                    {screen !== 'unit' ? (
                        <div className="cp-main-ready">
                            <ReadyCheckBanner />
                        </div>
                    ) : null}
                    <ScreenHost screens={screens} />
                </main>
            </div>
        </TabletFrame>
    );
}
