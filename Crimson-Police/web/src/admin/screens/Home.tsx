// Admin UI · Home (screen key 'admin_home'): the screen the Admin UI opens on, a dashboard read from one batched

// Admin UI · Home (screen key 'admin_home'): the screen the Admin UI opens on, a dashboard read from one batched
// callback (admin:getHome, modules/adminhome) once a minute and again shortly after a push that can change it
// ('operation', 'builder', 'nav'). Live now: officers on duty, the runs going and the queues waiting, each a tile
// that opens its screen. Alerts: Problems, today's refused starts, Config health and the last mission load. Shortcuts:
// the tiles Config.AdminUi.homeShortcuts names, in its order; four of them hold a quick form
// (admin/components/HomeForms) that does the job right there, and Open still opens the full screen. The tiles and
// lines come from admin/components/adminHome.ts.

import { useEffect, useRef, type ReactNode } from 'react';
import { Badge, Button, Card, Icon, Screen } from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatNumber } from '../../shared/format';
import { usePush, useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate } from '../../shared/navigation';
import { NEW_MISSION_PARAMS } from '../../builder/quickMission';
import { MissionSwitchForm, PayForm, PointsForm, QuickSettingsForm } from '../components/HomeForms';
import type { AdminHomeData, HomeShortcutKey } from '../../types/admin_system';
import { alertLines, liveTiles, shortcutsOf, waitingCount, type ShortcutDef } from '../components/adminHome';
import './Home.css';

// A push asks again once, this long after the first one (a busy run sends many).
const PUSH_GAP_MS = 2000;

// The quick form a shortcut holds on Home (none: the tile only opens its screen).
const FORMS: Partial<Record<HomeShortcutKey, () => ReactNode>> = {
    missionSwitch: () => <MissionSwitchForm />,
    pay: () => <PayForm />,
    points: () => <PointsForm />,
    settings: () => <QuickSettingsForm />,
};

// One admin:getHome request, asked again a moment after an 'operation', 'builder' or 'nav' push.
function useHome() {
    const req = useRequest<AdminHomeData>('admin:getHome', {}, { pollMs: 60000 });
    const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
    const refetch = req.refetch;
    const later = () => {
        if (timer.current) return;
        timer.current = setTimeout(() => {
            timer.current = null;
            void refetch();
        }, PUSH_GAP_MS);
    };
    usePush('operation', later);
    usePush('builder', later);
    usePush('nav', later);
    useEffect(
        () => () => {
            if (timer.current) clearTimeout(timer.current);
        },
        [],
    );
    return req;
}

function Shortcut({ def }: { def: ShortcutDef }) {
    const navigate = useNavigate();
    const params = def.key === 'newMission' ? { ...NEW_MISSION_PARAMS } : def.params;
    const form = FORMS[def.key];
    return (
        <Card className="admin-home-tile" padding="md">
            <div className="admin-home-tile__head">
                <span className="admin-home-tile__icon" aria-hidden>
                    <Icon name={def.icon} size={20} />
                </span>
                <div className="admin-home-tile__titles">
                    <div className="admin-home-tile__title">{t(def.title)}</div>
                    <div className="admin-home-tile__text">{t(def.text)}</div>
                </div>
            </div>
            {form ? form() : null}
            <div className="admin-home-tile__actions">
                <Button
                    variant="primary"
                    size="sm"
                    iconRight="chevronRight"
                    onClick={() => navigate(def.screen, params)}
                >
                    {t('admin.home.open')}
                </Button>
            </div>
        </Card>
    );
}

// Live now: one tile per count (officers on duty, runs going, each queue); a click opens its screen. Under the
// tiles, the departments on duty and the first runs as chips.
function LiveNow({ data }: { data: AdminHomeData | null }) {
    const navigate = useNavigate();
    const tiles = liveTiles(data);
    const waiting = waitingCount(tiles);
    const depts = asArray(data?.live?.departments).filter(d => d.n > 0);
    const runs = data?.live?.runs;
    const rows = asArray(runs?.rows);
    return (
        <Card
            className="admin-home-live"
            title={t('admin.home.live_title')}
            subtitle={
                data
                    ? waiting > 0
                        ? t('admin.home.live_waiting', { n: formatNumber(waiting) })
                        : t('admin.home.live_calm')
                    : t('admin.home.unknown')
            }
            icon="activity"
            highlight={waiting > 0 ? 'warning' : undefined}
        >
            <div className="admin-home-stats">
                {tiles.map(l => (
                    <button
                        type="button"
                        key={l.key}
                        className={`admin-home-stat${l.waits && l.n > 0 ? ' admin-home-stat--waiting' : ''}`}
                        onClick={() => navigate(l.screen, l.params)}
                    >
                        <span className="admin-home-stat__label">
                            <Icon name={l.icon} size={14} />
                            <span>{t(l.label)}</span>
                        </span>
                        <span className="admin-home-stat__value cp-num">{formatNumber(l.n)}</span>
                    </button>
                ))}
            </div>
            {depts.length > 0 ? (
                <div className="admin-home-live__meta">
                    {depts.map(d => `${d.label} ${formatNumber(d.n)}`).join(' · ')}
                </div>
            ) : null}
            {rows.length > 0 ? (
                <div className="admin-home-live__runs">
                    {rows.map(r => (
                        <button
                            type="button"
                            key={r.runId}
                            className="admin-home-live__run"
                            onClick={() => navigate('admin_live')}
                        >
                            <span className="admin-home-live__label">{r.missionLabel}</span>
                            <span className="admin-home-live__meta">
                                {t('admin.home.live_people', { n: formatNumber(r.people) })}
                            </span>
                            {r.test ? (
                                <Badge size="sm" tone="accent">
                                    {t('admin.home.live_test')}
                                </Badge>
                            ) : null}
                        </button>
                    ))}
                    {runs && runs.n > rows.length ? (
                        <span className="admin-home-live__more">
                            {t('admin.home.live_more', { n: formatNumber(runs.n - rows.length) })}
                        </span>
                    ) : null}
                </div>
            ) : null}
        </Card>
    );
}

// Alerts: each line a count that opens the screen where it is fixed.
function Alerts({ data, failed, retry }: { data: AdminHomeData | null; failed: boolean; retry: () => void }) {
    const navigate = useNavigate();
    const lines = alertLines(data);
    const waiting = waitingCount(lines);
    return (
        <Card
            className="admin-home-alerts"
            title={t('admin.home.alerts_title')}
            subtitle={
                data
                    ? waiting > 0
                        ? t('admin.home.alerts_some', { n: formatNumber(waiting) })
                        : t('admin.home.alerts_none')
                    : t('admin.home.unknown')
            }
            icon={waiting > 0 ? 'alert' : 'checkCircle'}
            highlight={waiting > 0 ? 'warning' : undefined}
        >
            {failed && !data ? (
                <button type="button" className="admin-home-check" onClick={retry}>
                    <span className="admin-home-check__label">{t('admin.home.load_failed')}</span>
                </button>
            ) : (
                <ul className="admin-home-checks">
                    {lines.map(l => (
                        <li key={l.key}>
                            <button
                                type="button"
                                className="admin-home-check"
                                onClick={() => navigate(l.screen, l.params)}
                            >
                                <span className="admin-home-check__label">{t(l.label)}</span>
                                <Badge size="sm" tone={l.n > 0 ? 'warning' : 'success'}>
                                    {formatNumber(l.n)}
                                </Badge>
                            </button>
                        </li>
                    ))}
                </ul>
            )}
        </Card>
    );
}

export default function AdminHome() {
    const { data, error, refetch } = useHome();
    const shortcuts = shortcutsOf(data);
    return (
        <Screen head="admin_home" subtitle={t('admin.home.subtitle')} className="admin-home-screen">
            <div className="admin-home-top">
                <LiveNow data={data} />
                <Alerts data={data} failed={!!error} retry={() => void refetch()} />
            </div>
            {shortcuts.length > 0 ? (
                <>
                    <h3 className="admin-home-heading">{t('admin.home.shortcuts_title')}</h3>
                    <div className="admin-home-grid">
                        {shortcuts.map(def => (
                            <Shortcut key={def.key} def={def} />
                        ))}
                    </div>
                </>
            ) : null}
        </Screen>
    );
}
