// The officer's current run, pinned above every Officer UI screen while a run is active.
// Data: request 'getRun' (ActiveMissionView or null) on mount, then the view each push topic 'run' carries (the same
// CP.Runs.view getRun returns). Click → Active Mission.

import { Badge, Countdown, Icon, TierBadge } from '../shared/components';
import { cx } from '../shared/cx';
import { ACTION_LEFT_SHOWN, asArray } from '../shared/data';
import { formatDistance } from '../shared/format';
import { useCountdown, usePush, useRequest } from '../shared/hooks';
import { t } from '../shared/i18n';
import { useNavigation } from '../shared/navigation';
import type { ActiveMissionView } from '../shared/types';

function RouteStatus({ route }: { route: ActiveMissionView['route'] }) {
    const left = useCountdown(route?.status === 'off' || route?.status === 'action' ? route.secondsLeft : null);
    if (!route) return null;
    if (route.status === 'off') {
        return (
            <span className="cp-runbar__status is-warning">
                <Icon name="alert" size={14} />
                {left !== null ? t('ui.runbar.off_route', { seconds: left }) : t('hud.route.off_nolimit')}
            </span>
        );
    }
    if (route.status === 'on') {
        const guide = route.required === false; // Config.Route.required off: the route is a guide
        return (
            <span className="cp-runbar__status is-ok">
                <Icon name="navigation" size={13} />
                {route.distance !== null && route.distance !== undefined
                    ? guide
                        ? t('ui.runbar.to_start_distance', { distance: formatDistance(route.distance) })
                        : t('ui.runbar.on_route_distance', { distance: formatDistance(route.distance) })
                    : guide
                      ? t('hud.route.guide')
                      : t('hud.route.on')}
            </span>
        );
    }
    if (route.status === 'arrived') {
        return (
            <span className="cp-runbar__status is-ok">
                <Icon name="mapPin" size={13} />
                {t('hud.route.arrived')}
            </span>
        );
    }
    if (route.status === 'action') {
        // a late officer: the run started before he arrived, he heads for the objective (Config.Route.lateArriveRange);
        // in the last 2 minutes of the time he has to reach it (Config.Route.followActionSeconds) the run bar says so
        if (left !== null && left <= ACTION_LEFT_SHOWN) {
            return (
                <span className="cp-runbar__status is-warning">
                    <Icon name="navigation" size={13} />
                    {t('ui.runbar.action_left', { seconds: left })}
                </span>
            );
        }
        return (
            <span className="cp-runbar__status is-ok">
                <Icon name="navigation" size={13} />
                {route.distance !== null && route.distance !== undefined
                    ? t('ui.runbar.action_distance', { distance: formatDistance(route.distance) })
                    : t('hud.route.action')}
            </span>
        );
    }
    return <span className="cp-runbar__status">{t('hud.route.disabled')}</span>;
}

export function RunBar() {
    const { data, setData, loading, refetch } = useRequest<ActiveMissionView | null>('getRun', {});
    const { navigate, screen } = useNavigation();
    // A 'run' push carrying the view applies as it is, with no getRun per push. The end of the run is
    // CP.Tablet.push(src, 'run', nil): Lua drops the nil field, so `data` arrives missing (undefined), not null.
    usePush<ActiveMissionView | null | undefined>('run', view => {
        if (view === null || view === undefined) setData(null);
        else if (typeof view === 'object' && typeof view.runId === 'string') setData(view);
        // Only the run's end (nil) asks again (a new run shows at once), and a push that lands while the first
        // fetch is still out (its older reply must not overwrite this view).
        if (loading || view === null || view === undefined) void refetch();
    });
    // A failed refetch keeps the view it already holds.
    if (!data || !data.runId) return null;

    const objectives = asArray(data.objectives);
    const done = objectives.filter(o => o.done).length;
    const total = objectives.length;
    const inProgress = data.state === 'in_progress';

    return (
        <button
            type="button"
            className={cx('cp-runbar', screen === 'active' && 'is-current', data.test && 'is-test')}
            onClick={() => navigate('active')}
            aria-label={t('ui.runbar.open')}
        >
            <span className={cx('cp-runbar__pulse', inProgress && 'is-live')} aria-hidden />
            <span className="cp-runbar__main">
                <span className="cp-runbar__eyebrow">
                    {data.test ? (
                        <Badge tone="warning" variant="solid" size="sm">
                            {t('hud.test_run')}
                        </Badge>
                    ) : null}
                    {inProgress ? t('ui.runbar.in_progress') : t('ui.runbar.en_route')}
                </span>
                <span className="cp-runbar__title">{data.missionLabel}</span>
            </span>
            <span className="cp-runbar__meta">
                <TierBadge tier={data.tier} expected={data.tierExpected} size="sm" />
                {inProgress ? (
                    <span className="cp-runbar__status">
                        <Icon name="checkCircle" size={13} />
                        {t('ui.runbar.objectives', { done, total })}
                    </span>
                ) : (
                    <RouteStatus route={data.route} />
                )}
                {data.remaining !== null && data.remaining !== undefined ? (
                    <span className="cp-runbar__timer">
                        <Icon name="clock" size={14} />
                        <Countdown seconds={data.remaining} paused={data.paused} warnBelow={60} dangerBelow={15} />
                    </span>
                ) : null}
            </span>
            <span className="cp-runbar__open">
                {t('ui.runbar.view')}
                <Icon name="chevronRight" size={15} />
            </span>
        </button>
    );
}
