// Admin UI: a separate full-screen panel (not the tablet), neutral admin theme (session.theme =

// Admin UI: a separate full-screen panel (not the tablet), neutral admin theme (session.theme =
// Config.AdminTheme), no watermark, the maintenance banner, and a sidebar with the admin-only badges: Home, then the
// screens by job (People, Missions, Real players, Money, Review, System), the rare tools under More, one search box
// (Ctrl+K) that jumps to any screen or tab, officer, mission or setting, and a breadcrumb (layouts/adminNav.ts).

import { Suspense, lazy, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from 'react';
import { Icon, IconButton, LayerRootContext, MaintenanceBanner, SearchInput } from '../shared/components';
import { useDebounced, useRequest, useViewport } from '../shared/hooks';
import { t } from '../shared/i18n';
import { useNavigation, type ScreenKey } from '../shared/navigation';
import { useSession, useTablet } from '../shared/session';
import { applyTheme } from '../shared/theme';
import type { AdminMissionsData } from '../types/builder_client';
import type { OfficerSearchData } from '../types/oversight';
import type { SettingsData } from '../types/settings';
import {
    ADMIN_GROUPS,
    ADMIN_JUMPS,
    FOUND_KINDS,
    SETTINGS_SEARCH,
    adminCrumbs,
    gearShown,
    adminFoldOf,
    adminGroupOf,
    adminTitleKey,
    globalResults,
    isSearchKey,
    type FoundItem,
} from './adminNav';
import { moneySearchWords } from './adminMoney';
import { navBadge, useNavCounts } from './navBadges';
// the gear's drawer (only this screen's settings), loaded on the first click
const ScreenSettings = lazy(() => import('../admin/components/ScreenSettings'));
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
    // Searching: the matching screens and tabs, officers, missions and settings in one list under a heading each,
    // then 'Search settings for ...'. The missions and the settings load once, when the first word is typed; the
    // officers come from the server's own search once the typing stops.
    const typed = find.trim();
    const searching = typed !== '';
    const [wanted, setWanted] = useState(false);
    useEffect(() => {
        if (searching) setWanted(true);
    }, [searching]);
    const has = (k: string) => screens.some(s => s.key === k);
    const officerQuery = useDebounced(typed, 300);
    const officerReq = useRequest<OfficerSearchData>(
        'admin:searchOfficers',
        { query: officerQuery, filters: {}, page: 1 },
        { skip: officerQuery.length < 2 || !has('admin_officers') },
    );
    const missionReq = useRequest<AdminMissionsData>(
        'admin:getMissions',
        {},
        { skip: !wanted || !has('admin_missions') },
    );
    const settingsReq = useRequest<SettingsData>('admin:getSettings', {}, { skip: !wanted || !has('admin_settings') });
    const settingsList = useMemo(
        () =>
            (settingsReq.data?.sections ?? []).flatMap(sec =>
                (sec.groups ?? []).flatMap(g => (g.settings ?? []).map(x => ({ path: x.path, label: x.label }))),
            ),
        [settingsReq.data],
    );
    const results: FoundItem[] = searching
        ? globalResults(
              {
                  screens: items.map(it => ({
                      key: it.key,
                      words: [
                          it.label,
                          t(`ui.screen.${it.key}`),
                          it.play ? groupLabel(it.play) : '',
                          // Money is found by its tabs' and its parts' names too (Payouts, Rewards, Payments)
                          ...(it.key === 'admin_money' ? moneySearchWords() : []),
                      ],
                  })),
                  jumps: ADMIN_JUMPS.map(j => {
                      const tab = t(j.label);
                      const on = t(adminTitleKey(j.screen));
                      return { jump: j, label: `${on} › ${tab}`, words: [tab, on] };
                  }),
                  officers: officerQuery === typed && officerQuery.length >= 2 ? officerReq.data?.officers : [],
                  missions: missionReq.data?.missions,
                  settings: settingsList,
              },
              typed,
          )
        : [];
    const iconOf = (r: FoundItem) =>
        r.kind === 'officers'
            ? 'user'
            : r.kind === 'missions'
              ? 'layers'
              : r.kind === 'settings'
                ? 'sliders'
                : (items.find(it => it.key === r.screen)?.icon ?? 'search');
    const found: SidebarItem[] = results.map(r => ({
        key: r.key,
        icon: iconOf(r),
        play: r.kind,
        label: r.key === SETTINGS_SEARCH ? t('ui.nav.search_settings', { q: typed }) : r.label,
    }));
    const foundSections = FOUND_KINDS.map(k => ({ key: k, label: t(`ui.nav.found.${k}`) }));
    const select = (k: string) => {
        const hit = results.find(r => r.key === k);
        setFind('');
        if (hit) navigate(hit.screen, hit.params);
        else navigate(k as ScreenKey);
    };
    // Ctrl+K puts the cursor in the search box from anywhere in the Admin UI
    const searchBox = useRef<HTMLSpanElement>(null);
    useEffect(() => {
        const onKey = (e: KeyboardEvent) => {
            if (!isSearchKey(e)) return;
            e.preventDefault();
            searchBox.current?.querySelector('input')?.focus();
        };
        window.addEventListener('keydown', onKey);
        return () => window.removeEventListener('keydown', onKey);
    }, []);
    const crumbs = adminCrumbs(screen);
    // every screen but Settings itself has a gear while the admin may open Settings
    const gear = gearShown(screen, has('admin_settings'));
    const [gearOpen, setGearOpen] = useState<string | null>(null);
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
                    sections={searching ? foundSections : sections}
                    search={
                        <span ref={searchBox} className="cp-admin__search">
                            <SearchInput
                                value={find}
                                onChange={setFind}
                                onEnter={() => found[0] && select(found[0].key)}
                                placeholder={t('ui.nav.search_screens')}
                                aria-label={t('ui.nav.search_screens')}
                            />
                        </span>
                    }
                    active={screen}
                    onSelect={select}
                    className="cp-sidebar--admin"
                    footer={<div className="cp-sidebar__hint">{t('ui.close_hint')}</div>}
                />
                <main className="cp-main cp-main--admin">
                    <MaintenanceBanner admin />
                    {crumbs.home || gear ? (
                        <div className="cp-admin__bar">
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
                            ) : (
                                <span />
                            )}
                            {gear ? (
                                <IconButton
                                    icon="sliders"
                                    size="sm"
                                    variant="secondary"
                                    label={t('settings.gear.open', { screen: t(adminTitleKey(screen)) })}
                                    onClick={() => setGearOpen(screen)}
                                />
                            ) : null}
                        </div>
                    ) : null}
                    <LayerRootContext.Provider value={layer}>
                        <ScreenHost screens={screens} />
                    </LayerRootContext.Provider>
                </main>
            </div>
            {gearOpen ? (
                <LayerRootContext.Provider value={layer}>
                    <Suspense fallback={null}>
                        <ScreenSettings
                            screen={gearOpen}
                            title={t(adminTitleKey(gearOpen))}
                            onClose={() => setGearOpen(null)}
                        />
                    </Suspense>
                </LayerRootContext.Provider>
            ) : null}
            <div ref={setLayer} className="cp-layer-root" />
        </div>
    );
}
