// Admin UI: a separate full-screen panel (not the tablet), neutral admin theme (session.theme =

// Config.AdminTheme), no watermark, the maintenance banner, and a sidebar with the admin-only badges: plain names,
// six described groups, the rare tools under More, a search box over the screens and the settings, and a breadcrumb
// over the screen (layouts/adminNav.ts).

import { useLayoutEffect, useRef, useState, type CSSProperties } from 'react';
import { Icon, IconButton, LayerRootContext, MaintenanceBanner, SearchInput } from '../shared/components';
import { useViewport } from '../shared/hooks';
import { t } from '../shared/i18n';
import { useNavigation, type ScreenKey } from '../shared/navigation';
import { useSession, useTablet } from '../shared/session';
import { applyTheme } from '../shared/theme';
import {
    ADMIN_GROUPS,
    SETTINGS_SEARCH,
    adminCrumbs,
    adminFoldOf,
    adminGroupOf,
    adminTitleKey,
    searchScreens,
} from './adminNav';
import { moneySearchWords } from './adminMoney';
import { navBadge, useNavCounts } from './navBadges';
import { NotificationBell } from './NotificationBell';
import { ScreenHost } from './ScreenHost';
import { screensFor } from './screens';
import { Sidebar, type SidebarItem } from './Sidebar';

export function AdminLayout() {
    const session = useSession();
    const { close } = useTablet();
    const { screen, navigate } = useNavigation();
    const screens = screensFor('admin', session);
    const counts = useNavCounts();
    const [find, setFind] = useState('');
    const groupLabel = (g: string) => t(`ui.nav.admin_group.${g}`);
    const items: SidebarItem[] = screens.map(s => ({
        key: s.key,
        label: t(adminTitleKey(s.key)),
        icon: s.icon,
        group: adminFoldOf(s.key),
        play: adminGroupOf(s.key),
        ...navBadge(s.key, counts),
    }));
    const sections = ADMIN_GROUPS.map(k => ({ key: k, label: groupLabel(k), hint: t(`ui.nav.admin_hint.${k}`) }));
    // Searching: the matching screens in one list, then 'Search settings for ...' while Settings shows
    const searching = find.trim() !== '';
    const found = searching
        ? searchScreens(
              items.map(it => ({
                  ...it,
                  words: [
                      it.label,
                      t(`ui.screen.${it.key}`),
                      it.play ? groupLabel(it.play) : '',
                      // Money is found by its tabs' and its old screens' names too (Payouts, Rewards, Payments)
                      ...(it.key === 'admin_money' ? moneySearchWords() : []),
                  ],
              })),
              find,
          ).map(({ words: _w, ...it }) => it)
        : [];
    if (searching && screens.some(s => s.key === 'admin_settings')) {
        found.push({ key: SETTINGS_SEARCH, label: t('ui.nav.search_settings', { q: find.trim() }), icon: 'sliders' });
    }
    const select = (k: string) => {
        setFind('');
        if (k === SETTINGS_SEARCH) navigate('admin_settings', { q: find.trim() });
        else navigate(k as ScreenKey);
    };
    const crumbs = adminCrumbs(screen);
    const homeShown = screens.some(s => s.key === 'admin_home');
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
                    items={searching ? found : items}
                    more={!searching ? t('ui.nav.more') : undefined}
                    sections={searching ? undefined : sections}
                    search={
                        <SearchInput
                            value={find}
                            onChange={setFind}
                            onEnter={() => found[0] && select(found[0].key)}
                            placeholder={t('ui.nav.search_screens')}
                            aria-label={t('ui.nav.search_screens')}
                        />
                    }
                    active={screen}
                    onSelect={select}
                    className="cp-sidebar--admin"
                    footer={<div className="cp-sidebar__hint">{t('ui.close_hint')}</div>}
                />
                <main className="cp-main cp-main--admin">
                    <MaintenanceBanner admin />
                    {crumbs.home ? (
                        <nav className="cp-admin__crumbs" aria-label={t('ui.nav.breadcrumb')}>
                            {homeShown ? (
                                <>
                                    <button type="button" onClick={() => navigate('admin_home')}>
                                        {t('ui.nav.plain.admin_home')}
                                    </button>
                                    <Icon name="chevronRight" size={12} />
                                </>
                            ) : null}
                            {crumbs.group ? (
                                <>
                                    <span>{groupLabel(crumbs.group)}</span>
                                    <Icon name="chevronRight" size={12} />
                                </>
                            ) : null}
                            <span aria-current="page">{t(adminTitleKey(screen))}</span>
                        </nav>
                    ) : null}
                    <LayerRootContext.Provider value={layer}>
                        <ScreenHost screens={screens} />
                    </LayerRootContext.Provider>
                </main>
            </div>
            <div ref={setLayer} className="cp-layer-root" />
        </div>
    );
}
