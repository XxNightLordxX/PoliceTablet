// Officer UI: tablet frame in the department theme, header, 7-screen sidebar, watermark,
// the pinned current-run bar and the Supervisor switch (only when session.roles.supervisor).

import { Button, Watermark } from '../shared/components';
import { t } from '../shared/i18n';
import { useNavigation, type ScreenKey } from '../shared/navigation';
import { useSession, useTablet } from '../shared/session';
import { Header } from './Header';
import { RunBar } from './RunBar';
import { ScreenHost } from './ScreenHost';
import { screensFor } from './screens';
import { Sidebar } from './Sidebar';
import { TABLET_H, TabletFrame } from './TabletFrame';

export function OfficerLayout() {
    const session = useSession();
    const { close, switchUi, switching } = useTablet();
    const { screen, navigate } = useNavigation();
    const screens = screensFor('officer', session);

    return (
        <TabletFrame theme={session.theme}>
            <Header session={session} ui="officer" onClose={close} />
            <div className="cp-tablet__body">
                <Sidebar
                    heading={t('ui.nav.officer')}
                    items={screens.map(s => ({ key: s.key, label: t(s.titleKey), icon: s.icon }))}
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
                    <ScreenHost screens={screens} />
                </main>
            </div>
        </TabletFrame>
    );
}
