// Supervisor UI: its own sidebar (6 screens, hidden when their action is not in session.actions; Department with
// the Review Queue's open-items badge; grouped by task and/or icons only per Config.Tablet, layouts/supervisorNav), department theme
// and the officer's look, watermark and the switch back to the Officer UI.

import { Button, MaintenanceBanner, Watermark } from '../shared/components';
import { setMoneyFormat } from '../shared/format';
import { t } from '../shared/i18n';
import { useNavigation, type ScreenKey } from '../shared/navigation';
import { useSession, useTablet } from '../shared/session';
import { Header } from './Header';
import { navBadge, useNavCounts } from './navBadges';
import { ScreenHost } from './ScreenHost';
import { screensFor } from './screens';
import { Sidebar } from './Sidebar';
import { SUPERVISOR_TASKS, supervisorNavOf, supervisorTaskOf } from './supervisorNav';
import { TABLET_H, TabletFrame } from './TabletFrame';

export function SupervisorLayout() {
    const session = useSession();
    const { close, switchUi, switching } = useTablet();
    const { screen, navigate } = useNavigation();
    const screens = screensFor('supervisor', session);
    const counts = useNavCounts();
    // Config.Tablet.supervisorByTask / supervisorCompact: only the sidebar's grouping and width change
    const nav = supervisorNavOf(session);
    setMoneyFormat(session.config.format);

    return (
        <TabletFrame theme={session.theme} prefs={session.prefs} profile={session.config.profile}>
            <Header session={session} ui="supervisor" onClose={close} />
            <div className="cp-tablet__body">
                <Sidebar
                    heading={t('ui.nav.supervisor')}
                    iconsOnly={nav.compact}
                    sections={
                        nav.byTask ? SUPERVISOR_TASKS.map(k => ({ key: k, label: t(`ui.nav.task.${k}`) })) : undefined
                    }
                    items={screens.map(s => ({
                        key: s.key,
                        label: t(s.titleKey),
                        icon: s.icon,
                        play: supervisorTaskOf(s.key, nav),
                        ...navBadge(s.key, counts),
                    }))}
                    active={screen}
                    onSelect={k => navigate(k as ScreenKey)}
                    footer={
                        <Button
                            variant="secondary"
                            block
                            icon="swap"
                            title={nav.compact ? t('ui.switch.officer') : undefined}
                            aria-label={nav.compact ? t('ui.switch.officer') : undefined}
                            loading={switching}
                            onClick={() => void switchUi('officer')}
                        >
                            {nav.compact ? null : t('ui.switch.officer')}
                        </Button>
                    }
                />
                <main className="cp-main">
                    <Watermark logo={session.logo} department={session.officer?.department} tabletHeight={TABLET_H} />
                    <MaintenanceBanner />
                    <ScreenHost screens={screens} />
                </main>
            </div>
        </TabletFrame>
    );
}
