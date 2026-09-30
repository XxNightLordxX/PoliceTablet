// Supervisor UI: its own sidebar (7 screens, hidden when their action is not in session.actions; Review Queue with
// its open-items badge), department theme and the officer's look, watermark and the switch back to the Officer UI.

import { Button, Watermark } from '../shared/components';
import { setMoneyFormat } from '../shared/format';
import { t } from '../shared/i18n';
import { useNavigation, type ScreenKey } from '../shared/navigation';
import { useSession, useTablet } from '../shared/session';
import { Header } from './Header';
import { navBadge, useNavCounts } from './navBadges';
import { ScreenHost } from './ScreenHost';
import { screensFor } from './screens';
import { Sidebar } from './Sidebar';
import { TABLET_H, TabletFrame } from './TabletFrame';

export function SupervisorLayout() {
    const session = useSession();
    const { close, switchUi, switching } = useTablet();
    const { screen, navigate } = useNavigation();
    const screens = screensFor('supervisor', session);
    const counts = useNavCounts();
    setMoneyFormat(session.config.format);

    return (
        <TabletFrame theme={session.theme} prefs={session.prefs} profile={session.config.profile}>
            <Header session={session} ui="supervisor" onClose={close} />
            <div className="cp-tablet__body">
                <Sidebar
                    heading={t('ui.nav.supervisor')}
                    items={screens.map(s => ({
                        key: s.key,
                        label: t(s.titleKey),
                        icon: s.icon,
                        ...navBadge(s.key, counts),
                    }))}
                    active={screen}
                    onSelect={k => navigate(k as ScreenKey)}
                    footer={
                        <Button
                            variant="secondary"
                            block
                            icon="swap"
                            loading={switching}
                            onClick={() => void switchUi('officer')}
                        >
                            {t('ui.switch.officer')}
                        </Button>
                    }
                />
                <main className="cp-main">
                    <Watermark logo={session.logo} department={session.officer?.department} tabletHeight={TABLET_H} />
                    <ScreenHost screens={screens} />
                </main>
            </div>
        </TabletFrame>
    );
}
