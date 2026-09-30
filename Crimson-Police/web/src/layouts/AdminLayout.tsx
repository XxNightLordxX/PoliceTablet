// Admin UI: a separate full-screen panel (not the tablet), neutral admin theme (session.theme =
// Config.AdminTheme), no watermark, 9-screen sidebar.

import { useLayoutEffect, useRef, useState, type CSSProperties } from 'react';
import { Icon, IconButton, LayerRootContext } from '../shared/components';
import { useViewport } from '../shared/hooks';
import { t } from '../shared/i18n';
import { useNavigation, type ScreenKey } from '../shared/navigation';
import { useSession, useTablet } from '../shared/session';
import { applyTheme } from '../shared/theme';
import { NotificationBell } from './NotificationBell';
import { ScreenHost } from './ScreenHost';
import { screensFor } from './screens';
import { Sidebar } from './Sidebar';

export function AdminLayout() {
    const session = useSession();
    const { close } = useTablet();
    const { screen, navigate } = useNavigation();
    const screens = screensFor('admin', session);
    const root = useRef<HTMLDivElement>(null);
    const [layer, setLayer] = useState<HTMLDivElement | null>(null);
    const { width, height } = useViewport();
    // Keep text readable above 1080p: zoom proportionally (never below 1).
    const zoom = Math.max(1, Math.min(width / 1920, height / 1080));

    useLayoutEffect(() => {
        applyTheme(root.current, session.theme);
    }, [session.theme]);

    const who = session.officer
        ? `${session.officer.name}${session.officer.callsign ? ` · ${session.officer.callsign}` : ''}`
        : t('ui.admin.server_admin');

    return (
        <div ref={root} className="cp-admin" style={zoom !== 1 ? ({ zoom } as CSSProperties) : undefined}>
            <header className="cp-admin__header">
                <div className="cp-admin__brand">
                    <span className="cp-admin__mark" aria-hidden>
                        <Icon name="shield" size={18} />
                    </span>
                    <div className="cp-header__titles">
                        <div className="cp-admin__title">{session.title || 'Crimson-Police'}</div>
                        <div className="cp-admin__subtitle">{t('ui.admin.subtitle')}</div>
                    </div>
                </div>
                <div className="cp-header__right">
                    <span className="cp-admin__who">
                        <Icon name="user" size={14} />
                        {who}
                    </span>
                    <NotificationBell />
                    <span className="cp-header__role cp-header__role--admin">
                        <Icon name="key" size={14} />
                        {t('ui.role.admin')}
                    </span>
                    <IconButton icon="x" label={t('ui.close')} onClick={close} />
                </div>
            </header>
            <div className="cp-admin__body">
                <Sidebar
                    heading={t('ui.nav.admin')}
                    items={screens.map(s => ({ key: s.key, label: t(s.titleKey), icon: s.icon }))}
                    active={screen}
                    onSelect={k => navigate(k as ScreenKey)}
                    className="cp-sidebar--admin"
                    footer={<div className="cp-sidebar__hint">{t('ui.close_hint')}</div>}
                />
                <main className="cp-main cp-main--admin">
                    <LayerRootContext.Provider value={layer}>
                        <ScreenHost screens={screens} />
                    </LayerRootContext.Provider>
                </main>
            </div>
            <div ref={setLayer} className="cp-layer-root" />
        </div>
    );
}
