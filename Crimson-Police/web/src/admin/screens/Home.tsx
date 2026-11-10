// Admin UI · Home (screen key 'admin_home'): the screen the Admin UI opens on. A Needs attention panel on top reads
// admin:getNeedsAttention (modules/adminhome) once a minute; its lines come from admin/components/needsAttention.ts.

// Admin UI · Home (screen key 'admin_home'): the screen the Admin UI opens on. A Needs attention panel on top reads
// admin:getNeedsAttention (modules/adminhome) once a minute; its lines come from admin/components/needsAttention.ts.
// Six tiles open the screens of the common jobs (navigate with params where the screen takes them); four of them
// hold a quick form (admin/components/HomeForms) that does the job right there, and Open still opens the full
// screen. A Live now strip shows the runs of the Live screen. Every number comes from a request another screen
// already makes.

import type { ReactNode } from 'react';
import { Badge, Button, Card, Icon, Screen, type IconName } from '../../shared/components';
import { asArray } from '../../shared/data';
import { formatNumber } from '../../shared/format';
import { useRequest } from '../../shared/hooks';
import { t } from '../../shared/i18n';
import { useNavigate, type AdminScreenKey, type ScreenParams } from '../../shared/navigation';
import type { ConfigHealthItem } from '../../shared/types';
import { useNavCounts } from '../../layouts/navBadges';
import { NEW_MISSION_PARAMS } from '../../builder/quickMission';
import { MissionSwitchForm, PayForm, PointsForm, QuickSettingsForm } from '../components/HomeForms';
import type { AdminLiveRunsData } from '../../types/admin_live';
import type { MissionLoadSummary } from '../../types/admin_missions';
import type { NeedsAttentionData } from '../../types/admin_system';
import { attentionLines, attentionWaiting } from '../components/needsAttention';
import { useAdminTitle } from '../../layouts/useAdminTitle';
import './Home.css';

// How many runs the Live now strip lists before "and N more".
const LIVE_MAX = 6;

interface TileProps {
    icon: IconName;
    title: string;
    text: string;
    screen: AdminScreenKey;
    params?: ScreenParams;
    children?: ReactNode;
}

function Tile({ icon, title, text, screen, params, children }: TileProps) {
    const navigate = useNavigate();
    return (
        <Card className="admin-home-tile" padding="md">
            <div className="admin-home-tile__head">
                <span className="admin-home-tile__icon" aria-hidden>
                    <Icon name={icon} size={20} />
                </span>
                <div className="admin-home-tile__titles">
                    <div className="admin-home-tile__title">{title}</div>
                    <div className="admin-home-tile__text">{text}</div>
                </div>
            </div>
            {children}
            <div className="admin-home-tile__actions">
                <Button variant="primary" size="sm" iconRight="chevronRight" onClick={() => navigate(screen, params)}>
                    {t('admin.home.open')}
                </Button>
            </div>
        </Card>
    );
}

interface CheckLine {
    key: string;
    label: string;
    value: string;
    bad: boolean;
    screen: AdminScreenKey;
    params?: ScreenParams;
}

// Something wrong?: the last mission load, Config health and stuck payments, each a link (the Problems lines and
// today's refused starts are in Needs attention).
function SomethingWrong() {
    const navigate = useNavigate();
    const load = useRequest<MissionLoadSummary>('admin:getMissionLoad', {}, { pushTopic: 'builder', pollMs: 60000 });
    const health = useRequest<ConfigHealthItem[]>('admin:getConfigHealth', {});
    const counts = useNavCounts();
    const refused = load.data ? asArray(load.data.failed).length + asArray(load.data.overrideFailed).length : 0;
    const unhealthy = asArray(health.data).filter(i => i.level !== 'ok').length;
    const stuck = counts.adminPayments ?? 0;
    const dash = t('admin.home.unknown');
    const lines: CheckLine[] = [
        {
            key: 'load',
            label: t('admin.home.check_load'),
            value: load.data
                ? t('admin.home.load_value', { loaded: formatNumber(load.data.loaded), refused: formatNumber(refused) })
                : dash,
            bad: refused > 0 || !!load.data?.error,
            screen: 'admin_missions',
        },
        {
            key: 'health',
            label: t('admin.home.check_health'),
            value: health.data ? formatNumber(unhealthy) : dash,
            bad: unhealthy > 0,
            screen: 'admin_permissions',
        },
        {
            key: 'payments',
            label: t('admin.home.check_payments'),
            value: formatNumber(stuck),
            bad: stuck > 0,
            screen: 'admin_money',
            params: { moneyTab: 'payments' },
        },
    ];
    const anyBad = lines.some(l => l.bad);
    return (
        <Card className="admin-home-tile" padding="md" highlight={anyBad ? 'warning' : undefined}>
            <div className="admin-home-tile__head">
                <span className="admin-home-tile__icon" aria-hidden>
                    <Icon name={anyBad ? 'alert' : 'checkCircle'} size={20} />
                </span>
                <div className="admin-home-tile__titles">
                    <div className="admin-home-tile__title">{t('admin.home.wrong_title')}</div>
                    <div className="admin-home-tile__text">
                        {anyBad ? t('admin.home.wrong_some') : t('admin.home.wrong_none')}
                    </div>
                </div>
            </div>
            <ul className="admin-home-checks">
                {lines.map(l => (
                    <li key={l.key}>
                        <button type="button" className="admin-home-check" onClick={() => navigate(l.screen, l.params)}>
                            <span className="admin-home-check__label">{l.label}</span>
                            <Badge size="sm" tone={l.bad ? 'warning' : 'success'}>
                                {l.value}
                            </Badge>
                        </button>
                    </li>
                ))}
            </ul>
        </Card>
    );
}

// Live now: the Live screen's request (every live run, tests too), one chip per run.
function LiveNow() {
    const navigate = useNavigate();
    const { data } = useRequest<AdminLiveRunsData>('admin:getLiveRuns', {}, { pollMs: 10000, pushTopic: 'operation' });
    const runs = asArray(data?.runs);
    return (
        <Card
            className="admin-home-live"
            title={t('admin.home.live_title')}
            subtitle={
                data
                    ? runs.length > 0
                        ? t('admin.home.live_count', { n: formatNumber(runs.length) })
                        : t('admin.home.live_none')
                    : t('admin.home.unknown')
            }
            icon="activity"
            actions={
                <Button size="sm" variant="secondary" iconRight="chevronRight" onClick={() => navigate('admin_live')}>
                    {t('admin.home.live_open')}
                </Button>
            }
        >
            {runs.length > 0 ? (
                <div className="admin-home-live__runs">
                    {runs.slice(0, LIVE_MAX).map(r => (
                        <button
                            type="button"
                            key={r.runId}
                            className="admin-home-live__run"
                            onClick={() => navigate('admin_live')}
                        >
                            <span className="admin-home-live__label">{r.missionLabel}</span>
                            <span className="admin-home-live__meta">
                                {t('admin.home.live_people', {
                                    n: formatNumber(asArray(r.participants).filter(p => p.status === 'active').length),
                                })}
                            </span>
                            {r.test ? (
                                <Badge size="sm" tone="accent">
                                    {t('admin.home.live_test')}
                                </Badge>
                            ) : null}
                        </button>
                    ))}
                    {runs.length > LIVE_MAX ? (
                        <span className="admin-home-live__more">
                            {t('admin.home.live_more', { n: formatNumber(runs.length - LIVE_MAX) })}
                        </span>
                    ) : null}
                </div>
            ) : null}
        </Card>
    );
}

// Needs attention: what is waiting for an admin, from one batched request
// (admin:getNeedsAttention), each line a count that opens its screen.
function NeedsAttention() {
    const navigate = useNavigate();
    const { data, error, refetch } = useRequest<NeedsAttentionData>('admin:getNeedsAttention', {}, { pollMs: 60000 });
    const lines = attentionLines(data);
    const waiting = attentionWaiting(lines);
    return (
        <Card
            className="admin-home-attention"
            title={t('admin.home.attention_title')}
            subtitle={
                data
                    ? waiting > 0
                        ? t('admin.home.attention_some', { n: formatNumber(waiting) })
                        : t('admin.home.attention_none')
                    : t('admin.home.unknown')
            }
            icon={waiting > 0 ? 'alert' : 'checkCircle'}
            highlight={waiting > 0 ? 'warning' : undefined}
        >
            {error && !data ? (
                <button type="button" className="admin-home-check" onClick={() => void refetch()}>
                    <span className="admin-home-check__label">{t('admin.home.attention_error')}</span>
                </button>
            ) : (
                <ul className="admin-home-checks admin-home-attention__lines">
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
    const screenTitle = useAdminTitle('admin_home');
    return (
        <Screen title={screenTitle} subtitle={t('admin.home.subtitle')} className="admin-home-screen">
            <NeedsAttention />
            <LiveNow />
            <div className="admin-home-grid">
                <Tile
                    icon="plus"
                    title={t('admin.home.new_title')}
                    text={t('admin.home.new_text')}
                    screen="admin_missions"
                    params={{ ...NEW_MISSION_PARAMS }}
                />
                <Tile
                    icon="layers"
                    title={t('admin.home.onoff_title')}
                    text={t('admin.home.onoff_form')}
                    screen="admin_missions"
                    params={{ tab: 'catalog' }}
                >
                    <MissionSwitchForm />
                </Tile>
                <Tile
                    icon="dollar"
                    title={t('admin.home.pay_title')}
                    text={t('admin.home.pay_form')}
                    screen="admin_money"
                >
                    <PayForm />
                </Tile>
                <Tile
                    icon="star"
                    title={t('admin.home.points_title')}
                    text={t('admin.home.points_form')}
                    screen="admin_officers"
                >
                    <PointsForm />
                </Tile>
                <Tile
                    icon="sliders"
                    title={t('admin.home.settings_title')}
                    text={t('admin.home.settings_form')}
                    screen="admin_settings"
                >
                    <QuickSettingsForm />
                </Tile>
                <SomethingWrong />
            </div>
        </Screen>
    );
}
